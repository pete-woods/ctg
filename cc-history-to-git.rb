require 'cc-history'
require 'fileutils'

if __FILE__ == $0 then
    parser = ClearCase::HistoryParser.new(*ARGV)

    def commit(author, date, comment)
	commitfile = ".commit-tmp"
	
	ENV['GIT_AUTHOR_NAME'] = author
	ENV['GIT_AUTHOR_EMAIL'] = ""
	ENV['GIT_AUTHOR_DATE'] = date.strftime("%Y-%m-%d %H:%M:%S")
	File.open(commitfile,"w") { |fp| fp.puts comment.empty? ? "(none)" : comment }
	system "git commit -F '#{commitfile}'"
	File.unlink(commitfile)
    end

    last_date = nil
    last_author = nil
    last_comment = nil

    parser.reconstruct_changes.each do |change|
	case change.kind
	when :add, :modify
	  FileUtils.mkdir_p(File.dirname(change.relpath))
	  FileUtils.cp(change.version.path, change.relpath)
	  system "git add '#{change.relpath}'"
	when :delete
	  system "git rm '#{change.relpath}'"
	end
	
	if not last_date then
	  last_date = change.owner_version.date
	  last_author = change.owner_version.user
	  last_comment = change.owner_version.comment
	else
	  details_changed = (last_author != change.owner_version.user or last_comment != change.owner_version.comment)
	  date_changed = (change.owner_version.date - last_date) > 60
	  if details_changed or date_changed then
	    commit(last_author, last_date, last_comment)
	    last_date = change.owner_version.date
	    last_author = change.owner_version.user
	    last_comment = change.owner_version.comment
	  end
	end
    end
    commit(last_author, last_date, last_comment)
end

