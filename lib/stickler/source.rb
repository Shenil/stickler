require 'uri'
require 'base64'
require 'progressbar'
require 'zlib'

module Stickler
  #
  # The representation of an upstream source from which stickler pulls gems.
  # This wraps up a Gem::SourceIndex along with some other meta information
  # about the source.
  #
  class Source
    class Error < ::StandardError; end

    # the uri of the source
    attr_reader :uri

    # stats from the upstream webserver
    attr_reader :upstream_stats

    # the source_group this source belongs to
    attr_accessor :source_group

    class << self
      #
      # Upstream headers to be used to detect if an upstream specs file is okay
      #
      def cache_detection_headers
        %w[ etag last-modified content-length ]
      end

      # 
      # The name of a marshaled file for a given uri
      #
      def marshal_file_name_for( uri )
        encoded_uri = Base64.encode64( uri ).strip
        return "#{encoded_uri}.specs.#{Gem.marshal_version}"
      end

      #
      # load a source from a cache file if it exists, otherwise
      # load it the normal way
      #
      def load( uri, source_group, opts = {} )
        cache_dir = source_group.cache_dir
        cache_file = File.join( cache_dir, marshal_file_name_for( uri ) )
        if File.exist?( cache_file ) then
          Console.info " * loading cache of #{uri}"
          source = Marshal.load( IO.read( cache_file ) )
          source.source_group = source_group
          source.refresh!
        else
          source = Source.new( uri, source_group, opts )
        end
        return source
      end
    end

    #
    # Create a new Source for a source_group.
    # Try and load the source from the cache if it can and if not, 
    # load it from the uri
    #
    def initialize( uri, source_group, opts = {})

      begin
        @uri = uri 
        ::URI.parse( uri ) # make sure it is valid

        @source_group = source_group
        @upstream_stats = {}

        if opts[:eager] then 
          logger.info "eager loading #{uri}"
          refresh!
        end

      rescue ::URI::Error => e
        raise Error, "Unable to create source from uri #{uri} : #{e}"
      end
    end

    #
    # Trigger a check to see if the source_specs should be refreshed
    #
    def refresh!
      source_specs
      nil
    end

    #
    # the local cache directory where the serialized version of this source is
    # held
    #
    def cache_dir
      source_group.cache_dir
    end

    def my_marshal_file_name
      Source.marshal_file_name_for( uri )
    end

    def logger
     ::Logging::Logger[self]
    end

    #
    # The predictable URI of the compressed Marshal file on the upstream gem
    # server.
    #
    def upstream_marshal_uri
      URI.join( uri, "specs.#{Gem.marshal_version}.gz" ).to_s
    end

    #
    # Fetch the compressed spec file from the upstream server
    #
    def fetch_spec( name, version, platform )
      spec_file_name = "#{name}-#{version}"
      spec_file_name += "-#{platform}" unless platform == Gem::Platform::RUBY
      spec_file_name += ".gemspec"

      spec_uri = URI.join( uri, "#{Gem::MARSHAL_SPEC_DIR}#{spec_file_name}" ).to_s
      local_spec = File.join( source_group.specification_dir, spec_file_name )
      if File.exist?( local_spec ) then
        spec = nil
        File.open( local_spec, "rb" ) { |f| spec = f.read }
      else
        spec_uri << ".rz"
        response = fetch( "get", spec_uri.to_s )
        spec = Zlib::Inflate.inflate response.body
        File.open( local_spec, "wb" ) { |f| f.write spec }
      end

      return Marshal.load( spec )
    end

    #
    # get the http response and follow redirection 
    #
    def fetch( method, uri, limit = 10 )
      response = nil
      while limit > 0
        uri = URI.parse( uri ) 

        logger.debug " -> #{method.upcase} #{uri}"
        connection = Net::HTTP.new( uri.host, uri.port )
        response = connection.send( method, uri.path )
        logger.debug " <- #{response.code} #{response.message}"
        case response
        when Net::HTTPSuccess then break
        when Net::HTTPRedirection then 
          uri = response['location']
          limit -= 1
        else 
          response.error!
        end
      end
      raise Error, "HTTP redirect to #{path} too deep" if limit == 0
      return response
    end
   
    #
    # shortcut for the latests specs
    #
    def latest_specs
      unless @latest_specs
        latest = {}
        source_specs.each do |name, version, original_platform|
          key = "#{name}-#{original_platform}"
          if latest[ key ].nil? or latest[ key ][1] < version then
            latest[ key ] = [ name, version, original_platform ]
          end
        end
        @latest_specs = latest
      end
      return @latest_specs.values
    end

    #
    # find all matching gems and return their Gem::Specification
    #
    def search( dependency )
      found = source_specs.select do |name, version, platform|
        dependency =~ Gem::Dependency.new( name, version )
      end
    end

    #
    # Access its source_specs
    #
    def source_specs
      return @source_specs unless last_check_expired?
      return @source_specs if source_specs_same_as_upstream?
      load_source_specs_from_upstream
      return @source_specs
    end

    #
    # load the source index member variable from the upstream source
    #
    def load_source_specs_from_upstream
      Console.info " * loading #{uri} from upstream"
      response = fetch( 'get', upstream_marshal_uri )
      body = StringIO.new( response.body )
      inflated = Zlib::GzipReader.new( body ).read
      begin
        @source_specs = Marshal.load( inflated ) 
        save!
      rescue => e
        Console.error e.backtrace.join("\n")
        raise Error, "Corrupt upstream source index of #{upstream_marshal_uri} : #{e}"
      end
      return @source_specs
    end

    #
    # return true if the last upstream check has expired
    #
    def last_check_expired?
      return true if @last_check.nil?
      return true if (Time.now - @last_check) >  5*60
    end

    #
    # return true if the current source_specs is the same as the upstream
    # source_specs as indicated by the HTTP headers
    def source_specs_same_as_upstream? 
      logger.debug "Checking if our our cached version of #{uri} is up to date"
      response = fetch( 'head', upstream_marshal_uri )
      @last_check = Time.now

      Source.cache_detection_headers.each do |key|
        unless response[key].nil?
          if upstream_stats[key] == response[key] then
            logger.debug "  our cache is up to date ( #{key} : #{response[key]} )"
            return true
          else
            upstream_stats[key] = response[key]
          end
        end
      end
      Console.info " * cache of #{uri} is out of date"
      return false
    end

    # 
    # The name of this source serialized as a marshaled object
    #
    def cache_file_name
      @cache_file_name ||= File.join( cache_dir, "#{my_marshal_file_name}" )
    end

    #
    # save self as a marshalled file to the cache file name
    #
    def save!
      logger.info "Writing source #{uri} to #{cache_file_name}"
      before_save_group = @source_group
      @source_group = nil
      File.open( cache_file_name, "wb" ) do |f|
        Marshal.dump( self, f )
      end
      @source_group = before_save_group
    end

    #
    # Destroy self and all gems that come from me
    #
    def destroy!
      logger.info "Destroying source #{uri} cache file #{cache_file_name}"
      FileUtils.rm_f cache_file_name
      Console.error " Still need to delete the gems from this source"
    end
  end
end
