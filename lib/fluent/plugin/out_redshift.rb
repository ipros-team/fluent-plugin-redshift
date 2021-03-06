module Fluent
  class RedshiftOutput < BufferedOutput
    Fluent::Plugin.register_output('redshift', self)

    # ignore load table error. (invalid data format)
    IGNORE_REDSHIFT_ERROR_REGEXP = /^ERROR:  Load into table '[^']+' failed\./

    def initialize
      super
      require 'aws-sdk'
      require 'zlib'
      require 'time'
      require 'tempfile'
      require 'pg'
      require 'json'
      require 'csv'
    end

    config_param :record_log_tag, :string, :default => 'log'
    config_param :time_key, :string, :default => 'time'
    config_param :time_format, :string, :default => '%Y-%m-%d %H:%M:%S'
    # s3
    config_param :aws_key_id, :string
    config_param :aws_sec_key, :string
    config_param :s3_bucket, :string
    config_param :s3_endpoint, :string, :default => nil
    config_param :path, :string, :default => ""
    config_param :timestamp_key_format, :string, :default => 'year=%Y/month=%m/day=%d/hour=%H/%Y%m%d-%H%M'
    config_param :utc, :bool, :default => false
    # redshift
    config_param :redshift_host, :string
    config_param :redshift_port, :integer, :default => 5439
    config_param :redshift_dbname, :string
    config_param :redshift_user, :string
    config_param :redshift_password, :string
    config_param :redshift_tablename, :string
    config_param :redshift_schemaname, :string, :default => nil
    config_param :redshift_copy_base_options, :string , :default => "TRUNCATECOLUMNS"
    config_param :redshift_copy_options, :string , :default => nil
    config_param :redshift_exclude_column, :string , :default => nil
    config_param :redshift_date_format, :string , :default => "YYYY-MM-DD"
    config_param :redshift_time_format, :string , :default => "YYYY-MM-DD HH:MI:SS"
    # file format
    config_param :file_type, :string, :default => 'json'  # json, tsv, csv, msgpack
    config_param :delimiter, :string, :default => nil
    # for debug
    config_param :log_suffix, :string, :default => ''

    def configure(conf)
      super
      @path = "#{@path}/" unless @path.end_with?('/') # append last slash
      @path = @path[1..-1] if @path.start_with?('/')  # remove head slash
      @utc = true if conf['utc']
      @db_conf = {
        host:@redshift_host,
        port:@redshift_port,
        dbname:@redshift_dbname,
        user:@redshift_user,
        password:@redshift_password
      }
      @delimiter = determine_delimiter(@file_type) if @delimiter.nil? or @delimiter.empty?
      $log.debug format_log("redshift file_type:#{@file_type} delimiter:'#{@delimiter}'")
      @copy_sql_template = "copy #{table_name_with_schema} from '%s' CREDENTIALS 'aws_access_key_id=%s;aws_secret_access_key=%s' delimiter '#{@delimiter}' DATEFORMAT AS '#{redshift_date_format}' TIMEFORMAT AS '#{redshift_time_format}' GZIP ESCAPE #{@redshift_copy_base_options} #{@redshift_copy_options};"
      $log.info "@copy_sql_template => #{@copy_sql_template}"
    end

    def start
      super
      # init s3 conf
      options = {
        :access_key_id     => @aws_key_id,
        :secret_access_key => @aws_sec_key
      }
      options[:s3_endpoint] = @s3_endpoint if @s3_endpoint
      @s3 = AWS::S3.new(options)
      @bucket = @s3.buckets[@s3_bucket]
    end

    def format(tag, time, record)
      record[@time_key] = Time.at(time).strftime(@time_format)
      if json?
        record.to_msgpack
      elsif msgpack?
        { @record_log_tag => record }.to_msgpack
      else
        "#{record[@record_log_tag]}\n"
      end
    end

    def write(chunk)
      $log.debug format_log("start creating gz.")

      # create a gz file
      tmp = Tempfile.new("s3-")
      tmp =
        if json? || msgpack?
          create_gz_file_from_structured_data(tmp, chunk, @delimiter)
        else
          create_gz_file_from_flat_data(tmp, chunk)
        end

      # no data -> skip
      unless tmp
        $log.debug format_log("received no valid data. ")
        return false # for debug
      end

      # create a file path with time format
      s3path = create_s3path(@bucket, @path)

      # upload gz to s3
      @bucket.objects[s3path].write(Pathname.new(tmp.path),
                                    :acl => :bucket_owner_full_control)

      # close temp file
      tmp.close!

      # copy gz on s3 to redshift
      s3_uri = "s3://#{@s3_bucket}/#{s3path}"
      sql = @copy_sql_template % [s3_uri, @aws_key_id , @aws_sec_key]
      $log.debug  format_log("start copying. s3_uri=#{s3_uri}")
      conn = nil
      begin
        conn = PG.connect(@db_conf)
        conn.exec(sql)
        $log.info format_log("completed copying to redshift. s3_uri=#{s3_uri}")
      rescue PG::Error => e
        $log.error format_log("failed to copy data into redshift. s3_uri=#{s3_uri}"), :error=>e.to_s
        raise e unless e.to_s =~ IGNORE_REDSHIFT_ERROR_REGEXP
        return false # for debug
      ensure
        conn.close rescue nil if conn
      end
      true # for debug
    end

    protected
    def format_log(message)
      (@log_suffix and not @log_suffix.empty?) ? "#{message} #{@log_suffix}" : message
    end

    private
    def json?
      @file_type == 'json'
    end

    def msgpack?
      @file_type == 'msgpack'
    end

    def create_gz_file_from_flat_data(dst_file, chunk)
      gzw = nil
      begin
        gzw = Zlib::GzipWriter.new(dst_file)
        chunk.write_to(gzw)
      ensure
        gzw.close rescue nil if gzw
      end
      dst_file
    end

    def create_gz_file_from_structured_data(dst_file, chunk, delimiter)
      # fetch the table definition from redshift
      redshift_table_columns = fetch_table_columns
      redshift_table_columns = redshift_table_columns.delete_if {|item| item == redshift_exclude_column }
      if redshift_table_columns == nil
        raise "failed to fetch the redshift table definition."
      elsif redshift_table_columns.empty?
        $log.warn format_log("no table on redshift. table_name=#{table_name_with_schema}")
        return nil
      end

      # convert json to tsv format text
      gzw = nil
      begin
        gzw = Zlib::GzipWriter.new(dst_file)
        chunk.msgpack_each do |record|
          begin
            hash = json? ? json_to_hash(record.to_json) : record[@record_log_tag]
            tsv_text = hash_to_table_text(redshift_table_columns, hash, delimiter)
            gzw.write(tsv_text) if tsv_text and not tsv_text.empty?
          rescue => e
            if json?
              $log.error format_log("failed to create table text from json. text=(#{record[@record_log_tag]})"), :error=>$!.to_s
            else
              $log.error format_log("failed to create table text from msgpack. text=(#{record[@record_log_tag]})"), :error=>$!.to_s
            end

            $log.error_backtrace
          end
        end
        return nil unless gzw.pos > 0
      ensure
        gzw.close rescue nil if gzw
      end
      dst_file
    end

    def determine_delimiter(file_type)
      case file_type
      when 'json', 'msgpack', 'tsv'
        "\t"
      when "csv"
        ','
      else
        raise Fluent::ConfigError, "Invalid file_type:#{file_type}."
      end
    end

    def fetch_table_columns
      conn = PG.connect(@db_conf)
      begin
        columns = nil
        conn.exec(fetch_columns_sql_with_schema) do |result|
          columns = result.collect{|row| row['column_name']}
        end
        columns
      ensure
        conn.close rescue nil
      end
    end

    def fetch_columns_sql_with_schema
      @fetch_columns_sql ||= if @redshift_schemaname
                               "select column_name from INFORMATION_SCHEMA.COLUMNS where table_schema = '#{@redshift_schemaname}' and table_name = '#{@redshift_tablename}' order by ordinal_position;"
                             else
                               "select column_name from INFORMATION_SCHEMA.COLUMNS where table_name = '#{@redshift_tablename}' order by ordinal_position;"
                             end
    end

    def json_to_hash(json_text)
      return nil if json_text.to_s.empty?

      JSON.parse(json_text)
    rescue => e
      $log.warn format_log("failed to parse json. "), :error => e.to_s
    end

    def hash_to_table_text(redshift_table_columns, hash, delimiter)
      return "" unless hash

      # extract values from hash
      val_list = redshift_table_columns.collect do |cn|
        val = hash[cn]
        val = JSON.generate(val) if val.kind_of?(Hash) or val.kind_of?(Array)

        if val.to_s.empty?
          nil
        else
          val.to_s
        end
      end

      if val_list.all?{|v| v.nil? or v.empty?}
        $log.warn format_log("no data match for table columns on redshift. data=#{hash} table_columns=#{redshift_table_columns}")
        return ""
      end

      generate_line_with_delimiter(val_list, delimiter)
    end

    def generate_line_with_delimiter(val_list, delimiter)
      val_list = val_list.collect do |val|
        if val.nil? or val.empty?
          ""
        else
          val.gsub(/\\/, "\\\\\\").gsub(/\t/, "\\\t").gsub(/\n/, "\\\n") # escape tab, newline and backslash
        end
      end
      val_list.join(delimiter) + "\n"
    end

    def create_s3path(bucket, path)
      timestamp_key = (@utc) ? Time.now.utc.strftime(@timestamp_key_format) : Time.now.strftime(@timestamp_key_format)
      i = 0
      begin
        suffix = "_#{'%02d' % i}"
        s3path = "#{path}#{timestamp_key}#{suffix}.gz"
        i += 1
      end while bucket.objects[s3path].exists?
      s3path
    end

    def table_name_with_schema
      @table_name_with_schema ||= if @redshift_schemaname
                                    "#{@redshift_schemaname}.#{@redshift_tablename}"
                                  else
                                    @redshift_tablename
                                  end
    end
  end
end
