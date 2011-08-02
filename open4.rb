#! /usr/bin/env ruby

require 'thread'
require 'set'

class Popen4
  @@active = []

  def self.exec(*cmd)
    args = cmd.dup
    args << {:stdin => :null}
    Popen4.new(*args) do |p|
      result = p.stdout.read
      status = p.wait
      if status != 0 then
        raise "#{cmd.join(" ")} failed with #{status}"
      end
      result
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
