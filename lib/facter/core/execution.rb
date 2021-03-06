require 'facter/util/config'

module Facter
  module Core
    module Execution

      module_function

      # Returns the locations to be searched when looking for a binary. This
      # is currently determined by the +PATH+ environment variable plus
      # `/sbin` and `/usr/sbin` when run on unix
      #
      # @return [Array<String>] the paths to be searched for binaries
      # @api private
      def search_paths
        if Facter::Util::Config.is_windows?
          ENV['PATH'].split(File::PATH_SEPARATOR)
        else
          # Make sure facter is usable even for non-root users. Most commands
          # in /sbin (like ifconfig) can be run as non priviledged users as
          # long as they do not modify anything - which we do not do with facter
          ENV['PATH'].split(File::PATH_SEPARATOR) + [ '/sbin', '/usr/sbin' ]
        end
      end

      # Determines the full path to a binary. If the supplied filename does not
      # already describe an absolute path then different locations (determined
      # by {search_paths}) will be searched for a match.
      #
      # Returns nil if no matching executable can be found otherwise returns
      # the expanded pathname.
      #
      # @param bin [String] the executable to locate
      # @return [String,nil] the full path to the executable or nil if not
      #   found
      #
      # @api public
      def which(bin)
        if absolute_path?(bin)
          return bin if File.executable?(bin)
          if Facter::Util::Config.is_windows? and File.extname(bin).empty?
            exts = ENV['PATHEXT']
            exts = exts ? exts.split(File::PATH_SEPARATOR) : %w[.COM .EXE .BAT .CMD]
            exts.each do |ext|
              destext = bin + ext
              if File.executable?(destext)
                Facter.warnonce("Using Facter::Util::Execution.which with an absolute path like #{bin} but no fileextension is deprecated. Please add the correct extension (#{ext})")
                return destext
              end
            end
          end
        else
          search_paths.each do |dir|
            dest = File.join(dir, bin)
            if Facter::Util::Config.is_windows?
              dest.gsub!(File::SEPARATOR, File::ALT_SEPARATOR)
              if File.extname(dest).empty?
                exts = ENV['PATHEXT']
                exts = exts ? exts.split(File::PATH_SEPARATOR) : %w[.COM .EXE .BAT .CMD]
                exts.each do |ext|
                  destext = dest + ext
                  return destext if File.executable?(destext)
                end
              end
            end
            return dest if File.executable?(dest)
          end
        end
        nil
      end

      # Determine in a platform-specific way whether a path is absolute. This
      # defaults to the local platform if none is specified.
      #
      # @param path [String] the path to check
      # @param platform [:posix,:windows,nil] the platform logic to use
      def absolute_path?(path, platform=nil)
        # Escape once for the string literal, and once for the regex.
        slash = '[\\\\/]'
        name = '[^\\\\/]+'
        regexes = {
          :windows => %r!^(([A-Z]:#{slash})|(#{slash}#{slash}#{name}#{slash}#{name})|(#{slash}#{slash}\?#{slash}#{name}))!i,
          :posix   => %r!^/!,
        }
        platform ||= Facter::Util::Config.is_windows? ? :windows : :posix

        !! (path =~ regexes[platform])
      end

      # Given a command line, this returns the command line with the
      # executable written as an absolute path. If the executable contains
      # spaces, it has to be put in double quotes to be properly recognized.
      #
      # @param command [String] the command line
      #
      # @return [String, nil] the command line with the executable's path
      # expanded, or nil if the executable cannot be found.
      def expand_command(command)
        if match = /^"(.+?)"(?:\s+(.*))?/.match(command)
          exe, arguments = match.captures
          exe = which(exe) and [ "\"#{exe}\"", arguments ].compact.join(" ")
        elsif match = /^'(.+?)'(?:\s+(.*))?/.match(command) and not Facter::Util::Config.is_windows?
          exe, arguments = match.captures
          exe = which(exe) and [ "'#{exe}'", arguments ].compact.join(" ")
        else
          exe, arguments = command.split(/ /,2)
          if exe = which(exe)
            # the binary was not quoted which means it contains no spaces. But the
            # full path to the binary may do so.
            exe = "\"#{exe}\"" if exe =~ /\s/ and Facter::Util::Config.is_windows?
            exe = "'#{exe}'" if exe =~ /\s/ and not Facter::Util::Config.is_windows?
            [ exe, arguments ].compact.join(" ")
          end
        end
      end

      # Overrides environment variables within a block of code.  The
      # specified values will be set for the duration of the block, after
      # which the original values (if any) will be restored.
      #
      # @overload with_env(values, { || ... })
      #
      # @param values [Hash<String=>String>] A hash of the environment
      #   variables to override
      #
      # @return [void]
      #
      # @api public
      def with_env(values)
        old = {}
        values.each do |var, value|
          # save the old value if it exists
          if old_val = ENV[var]
            old[var] = old_val
          end
          # set the new (temporary) value for the environment variable
          ENV[var] = value
        end
        # execute the caller's block, capture the return value
        rv = yield
      # use an ensure block to make absolutely sure we restore the variables
      ensure
        # restore the old values
        values.each do |var, value|
          if old.include?(var)
            ENV[var] = old[var]
          else
            # if there was no old value, delete the key from the current environment variables hash
            ENV.delete(var)
          end
        end
        # return the captured return value
        rv
      end

      # Executes a program and return the output of that program.
      #
      # Returns nil if the program can't be found, or if there is a problem
      # executing the code.
      #
      # @param code [String] the program to run
      # @return [String, nil] the output of the program or nil
      #
      # @api public
      #
      # @note Since Facter 1.5.8 this strips trailing newlines from the
      #   returned value. If a fact will be used by versions of Facter older
      #   than 1.5.8 then you should call chomp the returned string.
      #
      # @overload exec(code)
      # @overload exec(code, interpreter = nil)
      #   @param [String] interpreter unused, only exists for backwards
      #     compatibility
      #   @deprecated
      def exec(code, interpreter = nil)
        Facter.warnonce "The interpreter parameter to 'exec' is deprecated and will be removed in a future version." if interpreter

        ## Set LANG to force i18n to C for the duration of this exec; this ensures that any code that parses the
        ## output of the command can expect it to be in a consistent / predictable format / locale
        with_env "LANG" => "C" do

          if expanded_code = expand_command(code)
            # if we can find the binary, we'll run the command with the expanded path to the binary
            code = expanded_code
          else
            # if we cannot find the binary return nil on posix. On windows we'll still try to run the
            # command in case it is a shell-builtin. In case it is not, windows will raise Errno::ENOENT
            return nil unless Facter::Util::Config.is_windows?
            return nil if absolute_path?(code)
          end

          out = nil

          begin
            out = %x{#{code}}.chomp
            Facter.warnonce "Using Facter::Util::Execution.exec with a shell built-in is deprecated. Most built-ins can be replaced with native ruby commands. If you really have to run a built-in, pass \"cmd /c your_builtin\" as a command (command responsible for this message was \"#{code}\")" unless expanded_code
          rescue Errno::ENOENT => detail
            # command not found on Windows
            return nil
          rescue => detail
            Facter.warn(detail)
            return nil
          end

          if out == ""
            return nil
          else
            return out
          end
        end
      end
    end
  end
end
