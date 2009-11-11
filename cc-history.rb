require 'time'

Checkin = Struct.new(:date,:user,:path, :relpath, :comment)
class Checkin
    attr_accessor :deleted_files
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

class CCHistoryParser
    def initialize(root, since=nil)
	@root = File.expand_path(root)
	@since = since
    end
    
    attr_reader :path, :since

    def parse
	since = @since ? "-since #{@since}" : ""
	fp = IO.popen("cleartool lshistory -recurse #{since} -fmt '%Nd\t%o\t%u\t%n\n%c\n_END_OF_COMMENT_\n' '#{@root}'")

	group = ChangeSetGroup.new

	while line = fp.gets
	    date,action,user,path = line.chomp("\n").split("\t")
	    next unless action == "checkin"

	    date = Time.parse(date.gsub("."," "))

	    comment = []
	    while line = fp.gets and line != "_END_OF_COMMENT_\n"
		comment << line.chomp
	    end

	    relpath = path[@root.length+1..-1].gsub(/@@.*/,'')
	    checkin = Checkin.new(date,user,path,relpath,comment.join("\n"))

	    if File.directory?(path) then
	      dir_changes = `cleartool diff -diff_format -pred '#{path}'`
	      checkin.deleted_files = []
	      dir_changes.split("\n").select { |line| line[0] == ?< }.each do |line|
	        file = line[/^< (.*) \S+ \S+$/,1]
		checkin.deleted_files << file
	      end
	    end

	    group.add checkin

	end
	return group
    end
end

if __FILE__ == $0 then
    parser = CCHistoryParser.new(ARGV[0], ARGV[1])
    csg = parser.parse
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

