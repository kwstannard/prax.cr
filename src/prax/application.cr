require "./application/path"
require "./application/finders"
require "../kill"
require "../spawn"

module Prax
  XIP_IO = /\A(.+)\.(?:\d+\.){4}xip\.io\Z/

  # TODO: extract spawn part to an Application::Spawner class/module
  class Application
    getter :name, :path, :started_at, :last_accessed_at

    def initialize(name)
      @name = name.to_s
      @path = Path.new(@name)
      @last_accessed_at = Time.now
    end

    def touch
      @last_accessed_at = Time.now
    end

    # FIXME: protect with a mutex for tread safety
    def start(restart = false)
      if started?
        return
      end

      action = restart ? "Restarting" : "Starting"

      if path.rack?
        Prax.logger.info "#{action} Rack Application: #{name} (port #{port})"
        return spawn_rack_application
      end

      if path.shell?
        Prax.logger.info "#{action} Shell Application: #{name} (port #{port})"
        return spawn_shell_application
      end
    end

    def stop(log = true)
      if pid = @pid
        Prax.logger.info "Killing Application: #{name}" if log
        Process.kill(pid, Signal::TERM)
        reap(pid)
        @pid = nil
      end
    end

    def started?
      !stopped?
    end

    def needs_restart?
      if path.always_restart?
        return true
      end

      if path.restart?
        return @started_at.to_i < File::Stat.new(path.restart_path).mtime.to_i
      end

      false
    end

    def restart
      stop(log: false)
      start(restart: true)
    end

    def stopped?
      @pid.nil?
    end

    def port
      @port ||= if path.rack? || path.shell?
                  find_available_port
                elsif path.forwarding?
                  path.port
                end.to_i
    end

    def connect
      socket = connect
      begin
        yield socket
      ensure
        socket.close
      end
    end

    private def connect
      #if path.rack?
      #  UNIXSocket.new(path.socket_path)
      #else
        TCPSocket.new("127.0.0.1", port)
      #end
    end

    private def find_available_port
      server = TCPServer.new(0)
      server.addr.ip_port
    ensure
      server.close if server
    end

    private def spawn_rack_application
      cmd = [] of String
      cmd += ["bundle", "exec"] if path.gemfile?
      cmd += ["rackup", "--host", "localhost", "--port", port.to_s]

      File.open(path.log_path, "w") do |log|
        @pid = Process.spawn(cmd, output: log, error: log, chdir: path.to_s)
      end

      wait!
    end

    private def spawn_shell_application
      cmd = ["sh", path.to_s]
      env = { PORT: port }

      File.open(path.log_path, "w") do |log|
        @pid = Process.spawn(cmd, env: env, output: log, error: log)
      end

      wait!
    end

    private def wait!
      timer = Time.now
      pid = @pid.not_nil!

      loop do
        sleep 0.1

        break unless alive?(pid)

        if connectable?(pid)
          @started_at = Time.utc_now
          return
        end

        if (Time.now - timer).total_seconds > 30
          Prax.logger.error "Timeout Starting Application: #{name}"
          stop
          break
        end
      end

      Prax.logger.error "Error Starting Application: #{name}"
      reap(pid)
      raise ErrorStartingApplication.new
    end

    private def connectable?(pid)
      sock = connect
      true
    rescue ex : Errno
      unless ex.errno == Errno::ECONNREFUSED
        reap(pid)
        raise ex
      end
      false
    ensure
      sock.close if sock
    end

    # TODO: SIGCHLD trap that will wait all child PIDs with WNOHANG
    private def reap(pid)
      Thread.new { Process.waitpid(pid) } if pid
    end

    private def alive?(pid)
      Process.waitpid(pid, LibC::WNOHANG)
      true
    rescue
      @pid = nil
      false
    end
  end
end
