#! /usr/bin/env ruby

require 'open4'
require 'set'
require 'tempfile'
require 'optparse'
require 'fileutils'

class String
  def shell_escape
    if self !~ /^[-a-zA-Z0-9_.\/]+$/ then
      "'" + self.gsub("'","'\\\\''") + "'"
    else
      self
    end
  end
end

module GitToClearCase

$PATCH_COUNTER = 0
class GitChange
  def initialize(file)
    @file = file
  end
  attr_reader :file
  
  def apply(cc)
    if not cc.preview then
      # TODO - confirm that old file is same as base
      FileUtils.cp(file, File.join(cc.view_path, file))
    end

    cc.output "cp -f #{File.join(Dir.pwd,file).shell_escape} #{file.shell_escape}"
  end
end

class GitChangeAdd < GitChange
  def calculate_checkouts(cc)
    cc.ensure_dirs File.dirname(file)
    
    if File.exists?(File.join(cc.view_path, file)) then
      raise "File already exists that would be added #{file.inspect}"
    end
    cc.checkout_dir File.dirname(file)
    cc.mkelem file, cc.file_message(file)
  end
end

class GitChangeDelete < GitChange
  def calculate_checkouts(cc)
    cc.checkout_dir File.dirname(file)
  end
    
  def apply(cc)
    message = cc.file_message(file)
    cc.cleartool "rmname", "-c", message, file
    cc.append_message File.dirname(file), message
  end
end

class GitChangeRename < GitChange
  def initialize(file, newfile)
    super(file)
    @newfile = newfile
  end
  
  attr_reader :newfile
  
  def calculate_checkouts(cc)
    cc.ensure_dirs File.dirname(file)
    cc.ensure_dirs File.dirname(newfile)
    cc.checkout_dir File.dirname(file)
    cc.checkout_dir File.dirname(newfile)
  end
    
  def apply(cc)
    message = cc.file_message(newfile)
    cc.cleartool "mv", "-c", message, file, newfile
    cc.append_message File.dirname(file), message
    cc.append_message File.dirname(newfile), message
  end
end

class GitChangeModify < GitChange
  def calculate_checkouts(cc)
    cc.checkout file, cc.file_message(file)
  end  
end

class GitToClearcase
  def initialize(view_path)
    @view_path = view_path
    @preview = true
    @dirs_checked_out = Set.new
    @checkouts = Hash.new { |h,k| h[k] = [] }
    @mkelems = []
    @ensure_dirs = Set.new
    @append_messages = Hash.new { |h,k| h[k] = [] }
  end
 
 attr_reader :rev_options, :view_path, :preview
 attr_accessor :preview
 
  def file_message(file)
      cmd = ["git","log","--reverse", "--format=format:%s%n%b",rev_options,"--",file].flatten
      Popen4.exec(*cmd).strip
  end
  
  def mkelem(file, message)
    @mkelems << [file, message]
  end
  
  def append_message(file, message)
    @append_messages[file] << message unless @append_messages[file].include?(message)
  end
  
  def checkout(file, message)
    @checkouts[message] << file
  end
  
  def checkin(file)
    @checkins[message] << file
  end
  
  def ensure_dirs(dir)
    @ensure_dirs.add(dir)
  end
 
  def checkout_dir(dir)
    if not @dirs_checked_out.include?(dir) then
      @dirs_checked_out.add(dir)
    end
  end

  def cleartool_n(*args)
    Dir.chdir(@view_path) do
      cmd = ["cleartool"] + args
      Popen4.exec *cmd
    end
  end

  def lsco
    my_checkouts = Set.new
    other_checkouts = Set.new
    cleartool_n("lsco", "-recurse", "-fmt", "%Bn,%Lu\\n").split("\n").each do |e|
      path, user = e.split(",")
      path.gsub!(%r{^\./},'')
      if user.start_with?(ENV['USER']) then
        my_checkouts << path
      else
        other_checkouts << path
      end
    end
    return my_checkouts, other_checkouts
  end
 
  def process(base_rev)
    @my_checkouts, @other_checkouts = lsco
    
    if not File.directory?(".git") then
      raise "Must run from top of git tree"
    end
  
    @rev_options = "#{base_rev}..HEAD"
    cmd = ["git","diff","-M", "--name-status", rev_options].flatten
    text = Popen4.exec(*cmd)
    edits = text.split("\n").map { |line| line.chomp("\n").split("\t") }

    @changes = []

    edits.each do |status, file, newfile|
      case status
      when "A"
        @changes << GitChangeAdd.new(file)
      when "M"
        @changes << GitChangeModify.new(file)
      when "D"
        @changes << GitChangeDelete.new(file)
      when /^R100/
        @changes << GitChangeRename.new(file, newfile)
      when /^R(.\d+)/
        if $1.to_i >= 50 then
          @changes << GitChangeRename.new(file, newfile)
	  @changes << GitChangeModify.new(newfile)
	else
	  @changes << GitChangeDelete.new(file)
	  @changes << GitChangeAdd.new(file)
	end
      else
        raise "Unknown status #{status} #{file} #{newfile}"
      end
    end
    
    if @changes.empty? then
      comment "Nothing to do"
      return
    end
    
    comment "Checking out files/directories"
    @changes.each do |c|
      c.calculate_checkouts(self)
    end
    
    @ensure_dirs.each do |d|
      do_ensure_dir_checkout(d)
    end

    remaining_checkouts = (@checkouts.values.flatten.to_set + @mkelems.map { |f,m| f }.to_set).intersection @other_checkouts
    if remaining_checkouts.size > 0 then
      puts remaining_checkouts.entries
      raise "Existing checkouts by someome else for files in the changeset"
    end
    
    @dirs_checked_out.each do |dir|
       if @my_checkouts.include?(dir) then
         comment "Already checked out: #{dir}"
       else
         cleartool "co", "-nc", dir if is_versioned?(dir)
       end
    end
    
    @ensure_dirs.each do |d|
      do_ensure_dir(d)
    end

    @checkouts.each do |message,files|
      remaining_files = []
      files.each do |file|
        if @my_checkouts.include?(file) then
	  comment "Already checked out: #{file}"
	  cleartool "chevent", "-replace", "-c", message, file
	  predecessor = cleartool_n("describe", "-fmt", "%f", file)
	  view_file = File.join(view_path, file)
	  File.unlink(view_file) if not preview and File.exists?(view_file)
	  # Don't get any more because we copy file directly
	  #cleartool "get", "-to", file, "#{file}@@#{predecessor}"
	  #File.chmod(File.stat(view_file).mode | 0200, view_file) if not preview
	else
	  remaining_files << file
	end
      end
      if remaining_files.size > 0 then
        cleartool "co", "-c", message, *remaining_files
      end
    end
    
    @mkelems.each do |file, message|
      if @my_checkouts.include?(file) then
        cleartool "chevent", "-replace", "-c", message, file
      else
        cleartool "mkelem", "-c", message, file
      end
      File.unlink(File.join(view_path,file)) if not preview
    end
    
    do_apply
    #do_checkin
  end
  
  def is_versioned?(f)
    return File.exists?(File.join(view_path,f + "@@"))
  end

  def do_ensure_dir_checkout(d)
    if d != '.' then
      if not is_versioned?(d) and is_versioned?(File.dirname(d)) then
        checkout_dir(File.dirname(d))
      else
        do_ensure_dir_checkout(File.dirname(d))
      end
    end
  end

  def do_ensure_dir(d)
    if d != '.' and not is_versioned?(d) then
      do_ensure_dir(File.dirname(d))
      cleartool "mkdir", "-nc", d
    end
  end

  def do_apply
    comment "Applying changes"
    @changes.each do |c|
      c.apply(self)
    end
    
    @append_messages.each do |file,messages|
      messages.each do |message|
      	cleartool "chevent", "-append", "-c", message, file
      end
    end
  end
  
  def do_checkin
    comment "Checking in files"
    @checkins.values.each do |files|
      cleartool "ci", "-nc", *files
    end
    
    comment "Checking in directories"
    @dirs_checked_out.each do |dir|
      cleartool "ci", "-nc", dir
    end
  end
 
  def comment(line)
    output "# #{line}"
  end
 
  def output(line)
    puts line
  end
 
  def show_command(*args)
    output args.map { |a| a.shell_escape }.join(" ")
  end
 
  def cleartool(*args)
    show_command "cleartool", *args
    if not @preview then
      Dir.chdir(@view_path) do
        cmd = ["cleartool"] + args
        Popen4.exec(*cmd)
      end
    end
  end

end

end
