require 'time'

module ClearCase

    Version = Struct.new(:date, :user, :oid, :path, :relpath, :comment)
    Change = Struct.new(:kind, :relpath, :owner_version, :version)

    class Version
      def plain_path
        path.gsub(/@@.*/,'')
      end
      
      def directory_changes
        STDERR.puts "Fetching directory changes for #{path}"
     	diff_output = `cleartool diff -diff_format -pred '#{path}'`
	changes = []
	diff_output.split("\n").each do |line|
	    file = line[/^. (.*?)\s+\S+\s+\S+$/,1]
	    case line
	    when / -> /
	      STDERR.puts "WARNING: Ignoring symlink #{line.inspect}"
	    when /^</
	      changes << Change.new(:delete, file, nil, nil) unless file[-1] == ?/
	    when /^>/
	      changes << Change.new(:add, file, nil, nil) unless file[-1] == ?/
	    end
	end
	changes
       end
    end


    class ChangeSet
	def initialize(checkin)
	    @user = checkin.user
	    @comment = checkin.comment
	    @checkins = [checkin]
	end

	def close_enough?(checkin)
	    return false unless @user == checkin.user and @comment == checkin.comment

	    @checkins.each do |c|
		return true if (c.date - checkin.date).abs < 300
	    end

	    return false
	end

	def add(checkin)
	    @checkins << checkin
	end

	def date
	    @checkins.first.date
	end

	attr_reader :user, :comment, :checkins

    end

    class ChangeSetGroup
	def initialize
	    @changesets = []
	end
	
	def add(checkin)
	    @changesets.each do |cs|
		if cs.close_enough?(checkin) then
		    cs.add(checkin)
		    return
		end
	    end

	    @changesets << ChangeSet.new(checkin)
	end

	def ordered_changesets
	    @changesets.sort_by { |cs| cs.date }
	end

	attr_reader :changesets

    end

    class HistoryParser
	def initialize(root, branch, since=nil)
	    @root = File.expand_path(root)
	    @branch = branch
	    @since = since

	    @versions = parse_versions
	end

	attr_reader :path, :since

	FORMAT = "%Nd\t%o\t%u\t%On\t%n\n%c\n_END_OF_COMMENT_\n"

	def parse_lshistory(fp)
	    versions = []

	    while line = fp.gets
		date,action,user,oid,path = line.chomp("\n").split("\t")
		next unless action == "checkin"

		date = Time.parse(date.gsub("."," "))
		
		comment = []
		while line = fp.gets and line != "_END_OF_COMMENT_\n"
		    comment << line.chomp
		end

		relpath = path[@root.length+1..-1].gsub(/@@.*/,'')
		versions << Version.new(date,user,oid,path,relpath,comment.join("\n"))
	    end

	    versions
	end
	
	def branch_option
	  if @branch then "-branch '#{@branch}'" else "" end
	end
	
	def since_option
	  if @since then "-since '#{@since}'" else "" end
	end

	def parse_versions
	    IO.popen("cleartool lshistory -recurse #{branch_option} #{since_option} -fmt '#{FORMAT}' '#{@root}'; cleartool lshistory -directory  #{branch_option} #{since_option} -fmt '#{FORMAT}' '#{@root}'") do |fp|
	      parse_lshistory(fp)
	    end
	end

	def find_added_version(container, name, before)
	  STDERR.puts "Looking for base version of '#{container}/#{name}' before #{before}"
	  hist = IO.popen("cleartool lshistory -fmt '#{FORMAT}' '#{container}/#{name}'") do |fp|
	     parse_lshistory(fp)
	  end
	  
	  hist.sort_by { |v| v.date }.reverse.each do |v|
	    if v.date < before then
	      return v
	    end
	  end
	  raise "Can't find added version #{name} in #{container} before #{before}"
	end

	def reconstruct_changes
	    sorted_versions = @versions.sort_by { |v| v.date }
	    last_version = {}
	    changes = []
	    sorted_versions.each do |v|
	      last_version[v.oid] = v
	      if File.directory?(v.path) then
	        v.directory_changes.each do |c|
		  relpath = File.join(v.relpath,c.relpath)
		  recent_version = last_version[relpath]
		  if c.kind == :add and not recent_version then
		    recent_version = find_added_version(v.path, c.relpath, v.date)
		    if not recent_version then
		      raise "Unable to find new version for add of #{relpath} at #{v.path} #{v.date}"
		    end
		  end
		  changes.reject! { |ec| ec.kind == :modify and ec.relpath == relpath }
		  changes << Change.new(c.kind, relpath, v, recent_version)
		end
	      else
	        changes << Change.new(:modify, v.relpath, v, v)
	      end
	    end
            
	    changes
	end
	
    end
end

if __FILE__ == $0 then
    parser = ClearCase::HistoryParser.new(ARGV[0], ARGV[1])
    csg = parser.reconstruct_changes
    csg.each do |change|
      puts "#{change.kind} #{change.relpath}"
    end
    exit
    csg.ordered_changesets.each do |cs|
	puts "#{cs.user} #{cs.date} #{cs.comment.inspect}"
	cs.checkins.each do |ci|
	    if ci.deleted_files then
		ci.deleted_files.each do |del|
		    puts " DELETED #{File.join(ci.relpath, del)}"
		end
	    end
	    puts "  #{ci.path}"
	end
    end
end

