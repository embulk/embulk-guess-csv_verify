module Embulk
  module Guess
    require 'embulk/guess/schema_guess'
    require 'embulk/logger'

    class CsvGuessPlugin < LineGuessPlugin
      Plugin.register_guess('csv_verify', self)

      def self.create_classloader
        jars = Dir["#{File.expand_path('../../../../classpath', __FILE__)}/**/*.jar"]
        urls = jars.map {|jar| java.io.File.new(File.expand_path(jar)).toURI.toURL }
        begin
          expected_temporary_variable_name = Java::org.embulk.jruby.JRubyPluginSource::PLUGIN_CLASS_LOADER_FACTORY_VARIABLE_NAME
        rescue => e
          raise PluginLoadError.new "Java's org.embulk.jruby.JRubyPluginSource does not define PLUGIN_CLASS_LOADER_FACTORY_VARIABLE_NAME unexpectedly."
        end
        if expected_temporary_variable_name != "$temporary_internal_plugin_class_loader_factory__"
          raise PluginLoadError.new "Java's org.embulk.jruby.JRubyPluginSource does not define PLUGIN_CLASS_LOADER_FACTORY_VARIABLE_NAME correctly."
        end
        factory = $temporary_internal_plugin_class_loader_factory__
        factory.create(urls, JRuby.runtime.getJRubyClassLoader())
      end

      CLASSLOADER = create_classloader
      CONFIG_MAPPER_FACTORY_CLASS = CLASSLOADER.loadClass("org.embulk.util.config.ConfigMapperFactory").ruby_class
      CONFIG_MAPPER_FACTORY = CONFIG_MAPPER_FACTORY_CLASS.builder.addDefaultModules.build
      LEGACY_PLUGIN_TASK_CLASS = CLASSLOADER.loadClass("org.embulk.standards.CsvParserPlugin$PluginTask").ruby_class
      LIST_FILE_INPUT_CLASS = CLASSLOADER.loadClass("org.embulk.util.file.ListFileInput").ruby_class
      LINE_DECODER_CLASS = CLASSLOADER.loadClass("org.embulk.util.text.LineDecoder").ruby_class
      CSV_GUESS_PLUGIN_CLASS = CLASSLOADER.loadClass("org.embulk.guess.csv.CsvGuessPlugin").ruby_class
      LEGACY_CSV_TOKENIZER_CLASS = CLASSLOADER.loadClass("org.embulk.standards.CsvTokenizer").ruby_class
      LEGACY_TOO_FEW_COLUMNS_EXCEPTION_CLASS = CLASSLOADER.loadClass("org.embulk.standards.CsvTokenizer$TooFewColumnsException").ruby_class
      LEGACY_INVALID_VALUE_EXCEPTION_CLASS = CLASSLOADER.loadClass("org.embulk.standards.CsvTokenizer$InvalidValueException").ruby_class

      DELIMITER_CANDIDATES = [
        ",", "\t", "|", ";"
      ]

      QUOTE_CANDIDATES = [
        "\"", "'"
      ]

      ESCAPE_CANDIDATES = [
        "\\", '"'
      ]

      NULL_STRING_CANDIDATES = [
        "null",
        "NULL",
        "#N/A",
        "\\N",  # MySQL LOAD, Hive STORED AS TEXTFILE
      ]

      COMMENT_LINE_MARKER_CANDIDATES = [
        "#",
        "//",
      ]

      MAX_SKIP_LINES = 10
      NO_SKIP_DETECT_LINES = 10

      def guess_lines(config, sample_lines)
        guessed_ruby = guess_lines_iter(config, sample_lines)

        begin
          guess_plugin_java = CSV_GUESS_PLUGIN_CLASS.new
          guessed_java = guess_plugin_java.guess_lines(config_to_java(config), config_to_java(sample_lines), Java::org.embulk.spi.Exec.getBufferAllocator)
          if guessed_java.nil?
            raise "embulk-guess-csv (Java) returned null."
          end
          guessed_ruby_converted = config_to_java(guessed_ruby)
          if !guessed_java.equals(guessed_ruby_converted)
            log_guess_diff(guessed_ruby, guessed_java, "decoders")
            log_guess_diff(guessed_ruby, guessed_java, "parser")
            raise "embulk-guess-csv has difference between Java/Ruby."
          end
        rescue Exception => e
          # Any error from the Java-based guess plugin should pass-through just with logging.
          Embulk.logger.error "[Embulk CSV guess verify] #{e.inspect}\n\t#{e.backtrace.join("\n\t")}"
        end

        # This plugin returns a result from the Ruby-based implementation.
        return guessed_ruby
      end

      def guess_lines_iter(config, sample_lines)
        return {} unless config.fetch("parser", {}).fetch("type", "csv") == "csv"

        parser_config = config["parser"] || {}
        if parser_config["type"] == "csv" && parser_config["delimiter"]
          delim = parser_config["delimiter"]
        else
          delim = guess_delimiter(sample_lines)
          unless delim
            # assuming single column CSV
            delim = DELIMITER_CANDIDATES.first
          end
        end

        parser_guessed = DataSource.new.merge(parser_config).merge({"type" => "csv", "delimiter" => delim})

        unless parser_guessed.has_key?("quote")
          quote = guess_quote(sample_lines, delim)
          unless quote
            if !guess_force_no_quote(sample_lines, delim, '"')
              # assuming CSV follows RFC for quoting
              quote = '"'
            else
              # disable quoting (set null)
            end
          end
          parser_guessed["quote"] = quote
        end
        parser_guessed["quote"] = '"' if parser_guessed["quote"] == ''  # setting '' is not allowed any more. this line converts obsoleted config syntax to explicit syntax.

        unless parser_guessed.has_key?("escape")
          if quote = parser_guessed["quote"]
            escape = guess_escape(sample_lines, delim, quote)
            unless escape
              if quote == '"'
                # assuming this CSV follows RFC for escaping
                escape = '"'
              else
                # disable escaping (set null)
              end
            end
            parser_guessed["escape"] = escape
          else
            # escape does nothing if quote is disabled
          end
        end

        unless parser_guessed.has_key?("null_string")
          null_string = guess_null_string(sample_lines, delim)
          parser_guessed["null_string"] = null_string if null_string
          # don't even set null_string to avoid confusion of null and 'null' in YAML format
        end

        # guessing skip_header_lines should be before guessing guess_comment_line_marker
        # because lines supplied to CsvTokenizer already don't include skipped header lines.
        # skipping empty lines is also disabled here because skipping header lines is done by
        # CsvParser which doesn't skip empty lines automatically
        sample_records = split_lines(parser_guessed, false, sample_lines, delim, {})
        skip_header_lines = guess_skip_header_lines(sample_records)
        sample_lines = sample_lines[skip_header_lines..-1]
        sample_records = sample_records[skip_header_lines..-1]

        unless parser_guessed.has_key?("comment_line_marker")
          comment_line_marker, sample_lines =
            guess_comment_line_marker(sample_lines, delim, parser_guessed["quote"], parser_guessed["null_string"])
          if comment_line_marker
            parser_guessed["comment_line_marker"] = comment_line_marker
          end
        end

        sample_records = split_lines(parser_guessed, true, sample_lines, delim, {})

        # It should fail if CSV parser cannot parse sample_lines.
        if sample_records.nil? || sample_records.empty?
          return {}
        end

        if sample_lines.size == 1
          # The file contains only 1 line. Assume that there are no header line.
          header_line = false

          column_types = SchemaGuess.types_from_array_records(sample_records[0, 1])

          unless parser_guessed.has_key?("trim_if_not_quoted")
            sample_records_trimmed = split_lines(parser_guessed, true, sample_lines, delim, {"trim_if_not_quoted" => true})
            column_types_trimmed = SchemaGuess.types_from_array_records(sample_records_trimmed)
            if column_types != column_types_trimmed
              parser_guessed["trim_if_not_quoted"] = true
              column_types = column_types_trimmed
            else
              parser_guessed["trim_if_not_quoted"] = false
            end
          end
        else
          # The file contains more than 1 line. If guessed first line's column types are all strings or boolean, and the types are
          # different from the other lines, assume that the first line is column names.
          first_types = SchemaGuess.types_from_array_records(sample_records[0, 1])
          other_types = SchemaGuess.types_from_array_records(sample_records[1..-1] || [])

          unless parser_guessed.has_key?("trim_if_not_quoted")
            sample_records_trimmed = split_lines(parser_guessed, true, sample_lines, delim, {"trim_if_not_quoted" => true})
            other_types_trimmed = SchemaGuess.types_from_array_records(sample_records_trimmed[1..-1] || [])
            if other_types != other_types_trimmed
              parser_guessed["trim_if_not_quoted"] = true
              other_types = other_types_trimmed
            else
              parser_guessed["trim_if_not_quoted"] = false
            end
          end

          header_line = (first_types != other_types && first_types.all? {|t| ["string", "boolean"].include?(t) }) || guess_string_header_line(sample_records)
          column_types = other_types
        end

        if column_types.empty?
          # TODO here is making the guessing failed if the file doesn't contain any columns. However,
          #      this may not be convenient for users.
          return {}
        end

        if header_line
          parser_guessed["skip_header_lines"] = skip_header_lines + 1
        else
          parser_guessed["skip_header_lines"] = skip_header_lines
        end

        parser_guessed["allow_extra_columns"] = false unless parser_guessed.has_key?("allow_extra_columns")
        parser_guessed["allow_optional_columns"] = false unless parser_guessed.has_key?("allow_optional_columns")

        if header_line
          column_names = sample_records.first.map(&:strip)
        else
          column_names = (0..column_types.size).to_a.map {|i| "c#{i}" }
        end
        schema = []
        column_names.zip(column_types).each do |name,type|
          if name && type
            schema << new_column(name, type)
          end
        end
        parser_guessed["columns"] = schema

        return {"parser" => parser_guessed}
      end

      def new_column(name, type)
        if type.is_a?(SchemaGuess::TimestampTypeMatch)
          {"name" => name, "type" => type, "format" => type.format}
        else
          {"name" => name, "type" => type}
        end
      end

      private

      def log_guess_diff(guessed_ruby_entire, guessed_java_entire, key)
        guessed_ruby = guessed_ruby_entire[key] || {}
        guessed_java = guessed_java_entire.getNestedOrGetEmpty(key)

        begin
          require 'json'
        rescue LoadError
          raise "The 'json' gem is not installed. No details compared."
        else
          guessed_java_hash = JSON.parse(guessed_java.toJson)
        end

        if guessed_java_hash && guessed_ruby != guessed_java_hash
          Embulk.logger.error "[Embulk CSV guess verify] '#{key}' has difference."
          Embulk.logger.error "[Embulk CSV guess verify] Java => #{guessed_java_hash.to_json}"
          Embulk.logger.error "[Embulk CSV guess verify] Ruby => #{guessed_ruby.to_json}"
        end
      end

      def config_to_java(config_ruby)
        case config_ruby
        when Hash then
          config_java = CONFIG_MAPPER_FACTORY.newConfigSource
          config_ruby.each do |key, value|
            config_java.set(key.to_java, config_to_java(value))
          end
          return config_java
        when Array then
          config_java = Java::java.util.ArrayList.new
          config_ruby.each do |v|
            config_java.add(config_to_java(v))
          end
          return Java::java.util.Collections.unmodifiableList(config_java)
        else
          return config_ruby.to_java
        end
      end

      def split_lines(parser_config, skip_empty_lines, sample_lines, delim, extra_config)
        null_string = parser_config["null_string"]
        config = parser_config.merge(extra_config).merge({"charset" => "UTF-8", "columns" => []})
        parser_task = config.load_config(LEGACY_PLUGIN_TASK_CLASS)
        data = sample_lines.map {|line| line.force_encoding('UTF-8') }.join(parser_task.getNewline.getString.encode('UTF-8'))
        sample = Buffer.from_ruby_string(data)
        decoder = Java::LineDecoder.new(Java::ListFileInput.new([[sample.to_java]]), parser_task)
        tokenizer = LEGACY_CSV_TOKENIZER_CLASS.new(decoder, parser_task)
        rows = []
        while tokenizer.nextFile
          while tokenizer.nextRecord(skip_empty_lines)
            begin
              columns = []
              while true
                begin
                  column = tokenizer.nextColumn
                  quoted = tokenizer.wasQuotedColumn
                  if null_string && !quoted && column == null_string
                    column = nil
                  end
                  columns << column
                rescue LEGACY_TOO_FEW_COLUMNS_EXCEPTION_CLASS
                  rows << columns
                  break
                end
              end
            rescue LEGACY_INVALID_VALUE_EXCEPTION_CLASS
              # TODO warning
              tokenizer.skipCurrentLine
            end
          end
        end
        return rows
      rescue
        # TODO warning if fallback to this ad-hoc implementation
        sample_lines.map {|line| line.split(delim) }
      end

      def guess_delimiter(sample_lines)
        delim_weights = DELIMITER_CANDIDATES.map do |d|
          counts = sample_lines.map {|line| line.count(d) }
          total = array_sum(counts)
          if total > 0
            stddev = array_standard_deviation(counts)
            stddev = 0.000000001 if stddev == 0.0
            weight = total / stddev
            [d, weight]
          else
            [nil, 0]
          end
        end

        delim, weight = *delim_weights.sort_by {|d,weight| weight }.last
        if delim != nil && weight > 1
          return delim
        else
          return nil
        end
      end

      def guess_quote(sample_lines, delim)
        delim_regexp = Regexp.escape(delim)
        quote_weights = QUOTE_CANDIDATES.map do |q|
          weights = sample_lines.map do |line|
            q_regexp = Regexp.escape(q)
            count = line.count(q)
            if count > 0
              weight = count
              weight += line.scan(/(?:\A|#{delim_regexp})\s*#{q_regexp}(?:(?!#{q_regexp}).)*\s*#{q_regexp}(?:$|#{delim_regexp})/).size * 20
              weight += line.scan(/(?:\A|#{delim_regexp})\s*#{q_regexp}(?:(?!#{delim_regexp}).)*\s*#{q_regexp}(?:$|#{delim_regexp})/).size * 40
              weight
            else
              nil
            end
          end.compact
          weights.empty? ? 0 : array_avg(weights)
        end
        quote, weight = QUOTE_CANDIDATES.zip(quote_weights).sort_by {|q,w| w }.last
        if weight >= 10.0
          return quote
        else
          return nil
        end
      end

      def guess_force_no_quote(sample_lines, delim, quote_candidate)
        delim_regexp = Regexp.escape(delim)
        q_regexp = Regexp.escape(quote_candidate)
        sample_lines.any? do |line|
          # quoting character appear at the middle of a non-quoted value
          line =~ /(?:\A|#{delim_regexp})\s*[^#{q_regexp}]+#{q_regexp}/
        end
      end

      def guess_escape(sample_lines, delim, quote)
        guessed = ESCAPE_CANDIDATES.map do |str|
          regexp = /#{Regexp.quote(str)}(?:#{Regexp.quote(delim)}|#{Regexp.quote(quote)})/
          counts = sample_lines.map {|line| line.scan(regexp).count }
          count = counts.inject(0) {|r,c| r + c }
          [str, count]
        end.select {|str,count| count > 0 }.sort_by {|str,count| -count }
        found = guessed.first
        return found ? found[0] : nil
      end

      def guess_null_string(sample_lines, delim)
        guessed = NULL_STRING_CANDIDATES.map do |str|
          regexp = /(?:^|#{Regexp.quote(delim)})#{Regexp.quote(str)}(?:$|#{Regexp.quote(delim)})/
          counts = sample_lines.map {|line| line.scan(regexp).count }
          count = counts.inject(0) {|r,c| r + c }
          [str, count]
        end.select {|str,count| count > 0 }.sort_by {|str,count| -count }
        found_str, found_count = guessed.first
        return found_str ? found_str : nil
      end

      def guess_skip_header_lines(sample_records)
        counts = sample_records.map {|records| records.size }
        (1..[MAX_SKIP_LINES, counts.length - 1].min).each do |i|
          check_row_count = counts[i-1]
          if counts[i, NO_SKIP_DETECT_LINES].all? {|c| c <= check_row_count }
            return i - 1
          end
        end
        return 0
      end

      def guess_comment_line_marker(sample_lines, delim, quote, null_string)
        exclude = []
        exclude << /^#{Regexp.escape(quote)}/ if quote && !quote.empty?
        exclude << /^#{Regexp.escape(null_string)}(?:#{Regexp.escape(delim)}|$)/ if null_string

        guessed = COMMENT_LINE_MARKER_CANDIDATES.map do |str|
          regexp = /^#{Regexp.quote(str)}/
          unmatch_lines = sample_lines.reject do |line|
            exclude.all? {|ex| line !~ ex } && line =~ regexp
          end
          match_count = sample_lines.size - unmatch_lines.size
          [str, match_count, unmatch_lines]
        end.select {|str,match_count,unmatch_lines| match_count > 0 }.sort_by {|str,match_count,unmatch_lines| -match_count }

        str, match_count, unmatch_lines = guessed.first
        if str
          return str, unmatch_lines
        else
          return nil, sample_lines
        end
      end

      def guess_string_header_line(sample_records)
        first = sample_records.first
        first.count.times do |column_index|
          lengths = sample_records.map {|row| row[column_index] }.compact.map {|v| v.to_s.size }
          if lengths.size > 1
            if array_variance(lengths[1..-1]) <= 0.2
              avg = array_avg(lengths[1..-1])
              if avg == 0.0 ? lengths[0] > 1 : (avg - lengths[0]).abs / avg > 0.7
                return true
              end
            end
          end
        end
        return false
      end

      def array_sum(array)
        array.inject(0) {|r,i| r += i }
      end

      def array_avg(array)
        array.inject(0.0) {|r,i| r += i } / array.size
      end

      def array_variance(array)
        avg = array_avg(array)
        array.inject(0.0) {|r,i| r += (i - avg) ** 2 } / array.size
      end

      def array_standard_deviation(array)
        Math.sqrt(array_variance(array))
      end
    end

  end
end
