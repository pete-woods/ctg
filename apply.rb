require 'thread'
require 'set'
require 'tempfile'
require 'optparse'

class Popen4
  @@active = []

  def self.exec(*cmd)
    args = cmd.dup
    args << {:stdin => :null}
    Popen4.new(*args) do |f|
      result = f.stdout.read
      status = f.wait
      if status.exitstatus != 0 then
        raise "#{cmd.join(" ")} failed with #{status}"
      end
      return result
    end
  end

  def initialize(*cmd)
    Popen4.cleanup
    
    if Hash === cmd.last then
      options = cmd.pop
    else
      options = {}
    end
    
    @wait_mutex = Mutex.new
    @stdin = @stdout = @stderr = nil
    @status = nil
    to_close = []
    
    if options.has_key?(:stdin) then
      child_stdin = options[:stdin]
      if child_stdin == :null then
        child_stdin = File.open("/dev/null","r")
	to_close << child_stdin
      end
    else
      child_stdin, @stdin = IO.pipe
      to_close << child_stdin
    end
    
    if options.has_key?(:stdout) then
      child_stdout = options[:stdout]
    else
      @stdout, child_stdout = IO.pipe
      to_close << child_stdout
    end
    
    @pid = fork do
      if child_stdin then
        @stdin.close if @stdin
	STDIN.reopen(child_stdin)
	child_stdin.close
      end
      
      if child_stdout then
        @stdout.close if @stdout
	STDOUT.reopen(child_stdout)
	child_stdout.close
      end
      
      begin
        Kernel.exec(*cmd)
      ensure
        exit!(1)
      end
    end
    
    to_close.each { |fd| fd.close }
    @stdin.sync = true if @stdin
    
    Thread.exclusive { @@active << self }
    if block_given? then
      begin
        yield self
      ensure
        close
      end
    end
  end
  
  def self.cleanup
    active = Thread.exclusive { @@active.dup }
    active.each do |inst|
      inst.poll
    end
  end
  
  attr_reader :stdin, :stdout, :pid
  
  def close
    [@stdin, @stdout].each do |fp|
      begin
        fp.close if fp and not fp.closed?
      rescue
      end
    end
  end
  
  def wait(flags=0)
    @wait_mutex.synchronize do
      wait_no_lock(flags)
    end
  end
  
  def wait_no_lock(flags=0)
    return @status if @status
    while result = Process.waitpid2(@pid, flags)
      if result[0] == @pid and (result[1].exited? or result[1].signaled?) then
        @status = result[1]
        Thread.exclusive { @@active.delete(self) }
        return @status
      end
    end
    nil
  end
  
  private :wait_no_lock
  
  def poll
    if @wait_mutex.try_lock then
      begin
        wait_no_lock(Process::WNOHANG)
      ensure
        @wait_mutex.unlock
      end
    else
      nil
    end
  end
  
  def kill(signal)
    Process.kill(signal, @pid)
  end
end

class String
  def shell_escape
    if self !~ /^[-a-zA-Z0-9_.\/]+$/ then
      "'" + self.gsub("'","'\''") + "'"
    else
      self
    end
  end
end


$PATCH_COUNTER = 0
class GitChange
  def initialize(file)
    @file = file
  end
  attr_reader :file
  
  def apply(cc)
    cmd = ["git", "diff", cc.rev_options, "--", file].flatten
    patch_data = Popen4.exec(*cmd)
    tf = Tempfile.new("patch#{$PATCH_COUNTER}")
    $PATCH_COUNTER += 1
    tf.write(patch_data)
    tf.close
    if not cc.preview then
      Dir.chdir(cc.view_path) do 
        Popen4.exec("git", "apply", tf.path)
      end
    end
    tf.unlink
    
    cc.output "(cd #{Dir.pwd.shell_escape} && git diff #{cc.rev_options} -- #{file.shell_escape}) | git apply"
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
    cleartool_n("lsco", "-recurse", "-fmt", "%Bn\\n").split("\n")
  end
 
  def process(base_rev)
    @existing_checkouts = lsco
    
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
      else
        raise "Unknown status #{status}"
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

    remaining_checkouts = @existing_checkouts - @checkouts.values.flatten - @mkelems.map { |f,m| f }
    if remaining_checkouts.size > 0 then
      puts remaining_checkouts
      raise "Existing checkouts for files not in the changeset"
    end
    
    @dirs_checked_out.each do |dir|
       if @existing_checkouts.include?(dir) then
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
        if @existing_checkouts.include?(file) then
	  comment "Already checked out: #{file}"
	  cleartool "chevent", "-replace", "-c", message, file
	  predecessor = cleartool_n("describe", "-fmt", "%f", file)
	  view_file = File.join(view_path, file)
	  File.unlink(view_file) if not preview
	  cleartool "get", "-to", file, "#{file}@@#{predecessor}"
	  File.chmod(File.stat(view_file).mode | 0200, view_file) if not preview
	else
	  remaining_files << file
	end
      end
      if remaining_files.size > 0 then
        cleartool "co", "-c", message, *remaining_files
      end
    end
    
    @mkelems.each do |file, message|
      if @existing_checkouts.include?(file) then
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

if __FILE__ == $0 then
  view_path = nil
  rev_range = nil
  preview = true
  ARGV.options do |opts|
    opts.on("--exec","Actually execute commands") { preview = false }

    opts.banner = "Usage: apply [options] VIEW_PATH BASE_REV"
    opts.parse!
  end
  
  view_path = ARGV.shift
  base_rev = ARGV.shift
  
  if not view_path or not File.directory?(view_path) or not base_rev then
    puts ARGV.options
    exit 1
  end
  
  gcc = GitToClearcase.new(view_path)
  gcc.preview = preview
  gcc.process(base_rev)

end
