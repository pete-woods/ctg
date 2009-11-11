require 'cc-history'
require 'fileutils'

if __FILE__ == $0 then
    parser = CCHistoryParser.new(ARGV[0], ARGV[1])
    csg = parser.parse
    csg.ordered_changesets.each do |cs|
	puts "#{cs.user} #{cs.date} #{cs.comment.inspect}"
	cs.checkins.each do |ci|
	    if File.directory?(ci.path) then
	      if ci.deleted_files then
	        ci.deleted_files.each do |file|
		  system "git rm '#{File.join(ci.relpath,file)}'"
		end
	      end
	    else
              FileUtils.cp(ci.path, ci.relpath)
	      system "git add '#{ci.relpath}'"
	    end
	end
	
	commitfile = ".commit-tmp"
	
	ENV['GIT_AUTHOR_NAME'] = cs.user
	ENV['GIT_AUTHOR_EMAIL'] = ""
	ENV['GIT_AUTHOR_DATE'] = cs.date.strftime("%Y-%m-%d %H:%M:%S")
	File.open(commitfile,"w") { |fp| fp.puts cs.comment.empty? ? "(none)" : cs.comment }
	system "git commit -F '#{commitfile}'"
	File.unlink(commitfile)
    end
end

