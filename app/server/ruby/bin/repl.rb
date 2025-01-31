
require 'readline'
require 'open3'
require 'monitor'
require_relative "../lib/sonicpi/osc/osc"
require_relative "../paths"
require_relative "../lib/sonicpi/promise"

## This is a very simple barebones REPL for Sonic Pi
## All stdin is sent to Sonic Pi for evaluation and output is sent to stdout
## It also ensures the server is kept alive.
## Type ? for help

module SonicPi
  class Repl
    def initialize(init_code=nil)
      @log_output = true
      @server_started_prom = Promise.new
      @supercollider_started_prom = Promise.new
      @print_monitor = Monitor.new

      daemon_stdin, daemon_stdout_and_err, daemon_wait_thr = Open3.popen2e Paths.ruby_path, Paths.daemon_path

      force_puts "-- Sonic Pi Daemon started with PID: #{daemon_wait_thr.pid}"
      force_puts "-- Log files are located at: #{Paths.log_path}"

      daemon_info_prom = Promise.new

      daemon_io_thr = Thread.new do
        daemon_stdout_and_err.each do |line|
          line = line.force_encoding("UTF-8")
          daemon_info_prom.deliver! line
          Thread.current.kill
        end
      end

      daemon_info = daemon_info_prom.get.split.map(&:to_i)

      daemon_port = daemon_info[0]
      gui_listen_to_spider_port = daemon_info[1]
      gui_send_to_spider_port = daemon_info[2]
      scsynth_port = daemon_info[3]
      osc_cues_port = daemon_info[4]
      tau_port = daemon_info[5]
      tau_booter_port = daemon_info[6]
      daemon_token = daemon_info[7]

      force_puts "-- OSC Cues port: #{osc_cues_port}"

      daemon_zombie_feeder = Thread.new do
        osc_client = OSC::UDPClient.new("localhost", daemon_port)

        at_exit do
          force_puts ""
          force_puts "Killing the Sonic Pi Daemon...", :red
          force_puts "The Daemon has been vanquished!", :red
          force_puts ""
          force_puts "Farewell, artistic coder.", :cyan
          force_puts "May you live code and prosper...", :cyan
          print_ascii_art
          osc_client.send("/daemon/exit", daemon_token)
        end

        loop do
          osc_client.send("/daemon/keep-alive", daemon_token)
          sleep 5
        end
      end

      repl_eval_osc_client = OSC::UDPClient.new("localhost", gui_send_to_spider_port)

      spider_incoming_osc_server = OSC::UDPServer.new(gui_listen_to_spider_port)
      add_incoming_osc_handlers!(spider_incoming_osc_server)

      force_puts "-- Waiting for Sonic Pi to boot..."
      Thread.new do
        while ! @server_started_prom.delivered?
          begin
            repl_eval_osc_client.send("/ping", daemon_token, "Hello from the REPL!")
          rescue Errno::ECONNREFUSED
          end
          sleep 0.5
        end
      end


      @server_started_prom.get
      @supercollider_started_prom.get
      force_puts "-- Sonic Pi Server started"
      force_puts "-- Setting amplitude to 0.3"
      repl_eval_osc_client.send("/mixer-amp", daemon_token, 0.3, 1)
      print_ascii_art
      repl_eval_osc_client.send("/run-code", daemon_token, init_code) if init_code
      force_puts ""
      force_puts "Welcome to the Sonic Pi REPL. Type code and press enter to evaluate it"
      force_puts "Type ? for help."
      force_puts "==="
      force_puts ""
      Readline.basic_quote_characters = "\"'`()"
      while buf = Readline.readline(">> ", true)
        buf = buf.strip
        case buf
        when "?"
          force_puts "This is a simple REPL for Sonic Pi."
          force_puts "Type in code and press enter to evaluate it."
          force_puts ""
          force_puts "You can also use the following commands:"
          force_puts "  ?            - Show this help message"
          force_puts "  ,            - Multiline edit mode"
          force_puts "  .            - Stop all runs"
          force_puts "  .l           - Toggle log output"
          force_puts "  .a 0.5       - Set the amplitude to 0.5 (range 0 -> 1), default 0.3."
          force_puts "  .q           - Quit"
        when "."
          repl_eval_osc_client.send("/stop-all-jobs", daemon_token)
        when ".l"
          @log_output = !@log_output
          if @log_output
            force_puts "Enabling log output..."
          else
            force_puts "Disabling log output..."
          end
        when ".q"
          force_puts "Quitting the REPL..."
          exit
        when /^\.a\s+([0-9.]+)$/
          force_puts "Setting amplitude to #{$1}"
          repl_eval_osc_client.send("/mixer-amp", daemon_token, $1.to_f, 1)
        when ","
          force_puts "Multiline edit mode. Finish with a comma on a new line."
          force_puts ""
          lines = []
          while line = Readline.readline("  ", true)
            break if line.strip == ","
            lines << line
          end

          lines_str = lines.join("\n")
          repl_eval_osc_client.send("/run-code", daemon_token, lines_str)
        else
          repl_eval_osc_client.send("/run-code", daemon_token, buf)
        end
      end
    end

    def print_message(msg)
      case msg[0]
      when 0
        async_puts msg[1], :green
      when 1
        async_puts msg[1], :cyan
      else
        async_puts msg[1], :white
      end
    end

    def print_multi_message(msg)
      job_id = msg[0]
      thread_name = msg[1]
      time = msg[2]
      size = msg[3]
      msgs = msg[4..-1]
      if thread_name == "\"\""
        async_puts "Run #{job_id}, Time #{time}", :bold
      else
        async_puts "Run #{job_id}, Thread #{thread_name}, Time #{time}", :bold
      end
      last_msg = msgs.pop
      _last_colour = msgs.pop
      msgs.each_cons(2) do |colour, msg|
        print_message [1, "├─ #{msg}"]
      end
      print_message [1, "└─ #{last_msg}"]
    end

    def async_puts(msg, colour = :white)
      @print_monitor.synchronize do
        print "\r#{' ' * (Readline.line_buffer.length + 3)}\r"
        repl_puts msg, colour
        begin
          Readline.redisplay
        rescue
        end
      end
    end

    def repl_puts(msg, colour = :white)
      if @log_output
        force_puts msg, colour
      end
    end

    def force_puts(msg, colour = :white)
      @print_monitor.synchronize do
        case colour
        when :red
          puts "\e[31m#{msg}\e[0m"
        when :green
          puts "\e[32m#{msg}\e[0m"
        when :blue
          puts "\e[34m#{msg}\e[0m"
        when :yellow
          puts "\e[33m#{msg}\e[0m"
        when :magenta
          puts "\e[35m#{msg}\e[0m"
        when :cyan
          puts "\e[36m#{msg}\e[0m"
        when :bold
          puts "\e[1m#{msg}\e[22m"
        else
          puts msg
        end

      end
    end


    def add_incoming_osc_handlers!(osc)
      osc.add_method("/scsynth/info") do |msg|
        async_puts "SuperCollider Info:", :blue
        async_puts "===================", :blue
        async_puts ""
        async_puts msg[0], :blue
        @supercollider_started_prom.deliver! true
      end

      osc.add_method("/version") do |msg|
        async_puts "Sonic Pi Version: #{msg[0]}"
        async_puts msg[1..-1].inspect
      end

      osc.add_method("/incoming/osc") do |msg|
        time = msg[0]
        id = msg[1]
        address = msg[2]
        args = msg[3]

        async_puts "Cue - #{time} - #{id} - #{address} - #{args}"
      end

      osc.add_method("/error") do |msg|
        job_id = msg[0]
        description = msg[1]
        trace = msg[2]
        line_number =  msg[3]

        force_puts "Error on line #{line_number} for Run #{job_id}", :red
        force_puts "  #{description}", :red
        force_puts "  #{trace}", :red
      end

      osc.add_method("/syntax_error") do |msg|
        job_id = msg[0]
        description = msg[1]
        error_line = msg[2]
        line_number =  msg[3]

        force_puts "Syntax error on line #{line_number} for Run #{job_id}", :blue
        force_puts "  #{error_line}", :blue
        force_puts "  #{description}", :blue
      end

      osc.add_method("/log/info") do |msg|
        print_message(msg)
      end

      osc.add_method("/log/multi_message") do |msg|
        return if msg == ""

        if msg.is_a?(Array)
          print_multi_message(msg)
        end
      end

      osc.add_method("/runs/all-completed") do
      end

      osc.add_method("midi/out-ports") do |msg|
        async_puts "MIDI OUT PORTS: #{msg[0]}"
      end

      osc.add_method("midi/in-ports") do |msg|
        async_puts "MIDI IN PORTS: #{msg[0]}"
      end

      osc.add_method("/exited") do
        async_puts "Sonic Pi has closed"
      end

      osc.add_method("/ack") do
        @server_started_prom.deliver! true
      end
    end

    def print_ascii_art
      force_puts '

                                ╘
                         ─       ╛▒╛
                          ▐╫       ▄█├
                   ─╟╛      █▄      ╪▓▀
         ╓┤┤┤┤┤┤┤┤┤  ╩▌      ██      ▀▓▌
          ▐▒   ╬▒     ╟▓╘    ─▓█      ▓▓├
          ▒╫   ▒╪      ▓█     ▓▓─     ▓▓▄
         ╒▒─  │▒       ▓█     ▓▓     ─▓▓─
         ╬▒   ▄▒ ╒    ╪▓═    ╬▓╬     ▌▓▄
         ╥╒   ╦╥     ╕█╒    ╙▓▐     ▄▓╫
                    ▐╩     ▒▒      ▀▀
                         ╒╪      ▐▄

       _____             __        ____  __
      / ___/____  ____  /_/____   / __ \/_/
      \__ \/ __ \/ __ \/ / ___/  / /_/ / /
     ___/ / /_/ / / / / / /__   / ____/ /
    /____/\____/_/ /_/_/\___/  /_/   /_/

   The Live Coding Music Synth for Everyone

            http://sonic-pi.net

      '
    end
  end
end

if ARGV[0] == "-h" || ARGV[0] == "--help"
  puts "Sonic Pi REPL"
  puts "  -h, --help           Show this help message"
  puts "  /path/to/script.rb   Starts the REPL and runs the given script"
  puts ""
  puts "Once in the REPL you may type in code and press enter to evaluate it."
  puts "You can also use the following commands:"
  puts "  ?            - Show the help message"
  puts "  ,            - Multiline edit mode"
  puts "  .            - Stop all runs"
  puts "  .l           - Toggle log output"
  puts "  .a 0.5       - Set the amplitude to 0.5 (range 0 -> 1)"
  puts "  .q           - Quit"
  puts ""
  puts "Note: set the SONIC_PI_HOME env variable to specify the location of the log files"
  puts "      otherwise it will default to Sonic Pi's standard location in the home directory"

  exit
elsif ARGV[0]
  script = ARGV[0]
  if File.exist?(script)
    code = File.read(script)
    SonicPi::Repl.new(code)
  else
    puts "File not found: #{script}"
    exit
  end
else
  SonicPi::Repl.new()
end