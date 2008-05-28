module AWS
  module S3    
    # All authentication is taken care of for you by the AWS::S3 library. None the less, some details of the two types
    # of authentication and when they are used may be of interest to some.
    #
    # === Header based authentication
    #
    # Header based authentication is achieved by setting a special <tt>Authorization</tt> header whose value 
    # is formatted like so:
    #
    #   "AWS #{access_key_id}:#{encoded_canonical}"
    #
    # The <tt>access_key_id</tt> is the public key that is assigned by Amazon for a given account which you use when
    # establishing your initial connection. The <tt>encoded_canonical</tt> is computed according to rules layed out 
    # by Amazon which we will describe presently.
    #
    # ==== Generating the encoded canonical string
    #
    # The "canonical string", generated by the CanonicalString class, is computed by collecting the current request method, 
    # a set of significant headers of the current request, and the current request path into a string. 
    # That canonical string is then encrypted with the <tt>secret_access_key</tt> assigned by Amazon. The resulting encrypted canonical 
    # string is then base 64 encoded.
    #
    # === Query string based authentication
    #
    # When accessing a restricted object from the browser, you can authenticate via the query string, by setting the following parameters:
    #
    #   "AWSAccessKeyId=#{access_key_id}&Expires=#{expires}&Signature=#{encoded_canonical}"
    # 
    # The QueryString class is responsible for generating the appropriate parameters for authentication via the
    # query string.
    #
    # The <tt>access_key_id</tt> and <tt>encoded_canonical</tt> are the same as described in the Header based authentication section. 
    # The <tt>expires</tt> value dictates for how long the current url is valid (by default, it will expire in 5 minutes). Expiration can be specified
    # either by an absolute time (expressed in seconds since the epoch), or in relative time (in number of seconds from now).
    # Details of how to customize the expiration of the url are provided in the documentation for the QueryString class.
    #
    # All requests made by this library use header authentication. When a query string authenticated url is needed, 
    # the S3Object#url method will include the appropriate query string parameters.
    #
    # === Full authentication specification
    #
    # The full specification of the authentication protocol can be found at
    # http://docs.amazonwebservices.com/AmazonS3/2006-03-01/RESTAuthentication.html    
    class Authentication
      constant :AMAZON_HEADER_PREFIX, 'x-amz-'
      
      # Signature is the abstract super class for the Header and QueryString authentication methods. It does the job
      # of computing the canonical_string using the CanonicalString class as well as encoding the canonical string. The subclasses
      # parameterize these computations and arrange them in a string form appropriate to how they are used, in one case a http request
      # header value, and in the other case key/value query string parameter pairs.
      class Signature < String #:nodoc:
        attr_reader :request, :access_key_id, :secret_access_key
  
        def initialize(request, access_key_id, secret_access_key, options = {})
          super()
          @request, @access_key_id, @secret_access_key = request, access_key_id, secret_access_key
          @options = options
        end
  
        private
    
          def canonical_string            
            options = {}
            options[:expires] = expires if expires?
            CanonicalString.new(request, options)
          end
          memoized :canonical_string
    
          def encoded_canonical
            digest   = OpenSSL::Digest::Digest.new('sha1')
            b64_hmac = Base64.encode64(OpenSSL::HMAC.digest(digest, secret_access_key, canonical_string)).strip
            url_encode? ? CGI.escape(b64_hmac) : b64_hmac
          end
          
          def url_encode?
            !@options[:url_encode].nil?
          end
          
          def expires?
            is_a? QueryString
          end
          
          def date
            request['date'].to_s.strip.empty? ? Time.now : Time.parse(request['date'])
          end
      end
      
      # Provides header authentication by computing the value of the Authorization header. More details about the
      # various authentication schemes can be found in the docs for its containing module, Authentication.
      class Header < Signature #:nodoc:
        def initialize(*args)
          super
          self << "AWS #{access_key_id}:#{encoded_canonical}"
        end
      end
      
      # Provides query string authentication by computing the three authorization parameters: AWSAccessKeyId, Expires and Signature.
      # More details about the various authentication schemes can be found in the docs for its containing module, Authentication.
      class QueryString < Signature #:nodoc:
        constant :DEFAULT_EXPIRY, 300 # 5 minutes
        
        def initialize(*args)
          super
          @options[:url_encode] = true
          self << build
        end
        
        private
          
          # Will return one of three values, in the following order of precedence:
          #
          #   1) Seconds since the epoch explicitly passed in the +:expires+ option
          #   2) The current time in seconds since the epoch plus the number of seconds passed in
          #      the +:expires_in+ option
          #   3) The current time in seconds since the epoch plus the default number of seconds (60 seconds)
          def expires
            return @options[:expires] if @options[:expires]
            date.to_i + (@options[:expires_in] || DEFAULT_EXPIRY)
          end
          
          # Keep in alphabetical order
          def build
            "AWSAccessKeyId=#{access_key_id}&Expires=#{expires}&Signature=#{encoded_canonical}"
          end
      end
      
      # The CanonicalString is used to generate an encrypted signature, signed with your secrect access key. It is composed of 
      # data related to the given request for which it provides authentication. This data includes the request method, request headers,
      # and the request path. Both Header and QueryString use it to generate their signature.
      class CanonicalString < String #:nodoc:
        class << self
          def default_headers
            %w(content-type content-md5)
          end

          def interesting_headers
            ['content-md5', 'content-type', 'date', amazon_header_prefix]
          end
          
          def amazon_header_prefix
            /^#{AMAZON_HEADER_PREFIX}/io
          end
        end
        
        attr_reader :request, :headers
        
        def initialize(request, options = {})
          super()
          @request = request
          @headers = {}
          @options = options
          # "For non-authenticated or anonymous requests. A NotImplemented error result code will be returned if 
          # an authenticated (signed) request specifies a Host: header other than 's3.amazonaws.com'"
          # (from http://docs.amazonwebservices.com/AmazonS3/2006-03-01/VirtualHosting.html)
          request['Host'] ||= DEFAULT_HOST
          build
        end
    
        private
          def build
            self << "#{request.method}\n"
            ensure_date_is_valid
            
            initialize_headers
            set_expiry!
        
            headers.sort_by {|k, _| k}.each do |key, value|
              value = value.to_s.strip
              self << (key =~ self.class.amazon_header_prefix ? "#{key}:#{value}" : value)
              self << "\n"
            end
            self << path
          end
      
          def initialize_headers
            identify_interesting_headers
            set_default_headers
          end
          
          def set_expiry!
            self.headers['date'] = @options[:expires] if @options[:expires]
          end
          
          def ensure_date_is_valid
            request['Date'] ||= Time.now.httpdate
          end

          def identify_interesting_headers
            request.each do |key, value|
              key = key.downcase # Can't modify frozen string so no bang
              if self.class.interesting_headers.any? {|header| header === key}
                self.headers[key] = value.to_s.strip
              end
            end
          end

          def set_default_headers
            self.class.default_headers.each do |header|
              self.headers[header] ||= ''
            end
          end

          def path
            [only_path, extract_significant_parameter].compact.join('?')
          end
          
          def extract_significant_parameter
            request.path[/[&?](acl|torrent|logging)(?:&|=|$)/, 1]
          end
          
          def only_path
            ("/" + request['Host'].gsub("#{DEFAULT_HOST}","").gsub(/\.$/,'') + request.path[/^[^?]*/]).gsub("//","/")
          end
      end
    end
  end
end