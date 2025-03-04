# frozen_string_literal: true

require '/usr/src/app/sinatra_template/utils' # provided by template
require_relative './property_definition'
module MuSearch
  ##
  # This class is responsible for building JSON documents from an IndexDefinition
  class DocumentBuilder
    def initialize(tika:, sparql_client:, attachment_path_base:, logger:)
      @tika = tika
      @sparql_client = sparql_client # authorized client from connection pool
      @attachment_path_base = attachment_path_base
      @cache_path_base = "/cache/"
      @logger = logger
    end

    ##
    # Builds a document to index for the given resource URI and index_definition
    def build_document_for_index(uri:, index_definition:)
      if index_definition.is_composite_index?
        fetch_document_for_composite_index(uri: uri, index_definition: index_definition)
      else
        fetch_document_to_index(uri: uri, properties: index_definition.properties)
      end
    end

    # Constructs a document to index for the given resource URI and configured properties.
    #
    # The properties are queried from the triplestore using the DocumentBuilder's SPARQL client
    # which is configured with the appropriate mu-auth-allowed-groupds.
    #
    # This is your one-stop shop to fetch all info to index a document.
    #   - uri: URI of the resource to fetch
    #   - properties: Array of properties as configured in the search config
    def fetch_document_to_index(uri: nil, properties: nil)
      # we include uuid because it may be used for folding
      properties["uuid"] = ["http://mu.semte.ch/vocabularies/core/uuid"] unless properties.key?("uuid")

      key_value_tuples = properties.collect do |key, prop_config|
        property_definition = PropertyDefinition.from_json_config(key, prop_config)
        if property_definition.type == "simple"
          prop_values = get_property_values(uri, key, property_definition.path)
          index_value = build_simple_property(prop_values)
        elsif property_definition.type == "language-string"
          index_value = [get_language_string_map(uri, property_definition.path)]
        elsif property_definition.type == "attachment"
          prop_values = get_property_values(uri, key, property_definition.path)
          index_value = build_file_field(prop_values)
        elsif property_definition.type == "nested"
          prop_values = get_property_values(uri, key, property_definition.path)
          index_value = build_nested_object(prop_values, prop_config["properties"])
        else
          raise "unexpected property type #{property_definition.type} is not handled in document builder"
        end
        [key, denumerate(index_value)]
      end
      Hash[key_value_tuples]
    end

    ##
    # construct a document for a composite index
    #
    # this is quite similar to a regular index,
    # but the provided resource (uri) could have multiple types and thus match multiple subtypes
    # in some cases this means different property paths may be mapped on the same field in the document
    # this is handled here by merging those documents as good as possible
    def fetch_document_for_composite_index(uri:, index_definition:)
      raise "document_builder: expected a composite index" unless index_definition.is_composite_index?

      merged_document = {}
      relevant_sub_indexes_for(uri, index_definition.composite_types).each do |sub_definition|
        properties = sub_definition.properties
        document = fetch_document_to_index(uri: uri, properties: properties)
        merged_document = smart_merge(merged_document, document)
      end
      merged_document
    end

    private
    # Selects the value(s) and their language for the given property of a resource
    # from the triplestore
    #   - uri: URI of the resource as a string
    #   - path: predicate path of the property to fetch
    # this groups string per language into their own field so we can maintain clean term frequencies
    # and configure an analyzer for each (sub)field.
    # strings without a provided language are mapped into a "default" field
    # see also https://www.elastic.co/guide/en/elasticsearch/guide/current/one-lang-fields.html
    def get_language_string_map(uri, path)
      predicate_s = MuSearch::SPARQL.make_predicate_string(path)
      query = <<SPARQL
    SELECT DISTINCT ?value ?language WHERE {
      #{SinatraTemplate::Utils.sparql_escape_uri(uri)} #{predicate_s} ?value.
      BIND(LANG(?value) as ?language)
    }
SPARQL
      sparql_results = @sparql_client.query(query)
      language_map =  Hash.new {|hash, key| hash[key] = [] }
      sparql_results.each do |result|
        lang = result[:language].to_s
        value = result[:value].to_s
        if ! lang.empty?
          language_map[lang] << value
        else
          language_map["default"] << value
        end
      end
      language_map
    end

    # Selects the value(s) for the given property of a resource
    # from the triplestore
    #   - uri: URI of the resource as a string
    #   - property_key: name of the variable to bind the result to
    #   - path: predicate path of the property to fetch
    def get_property_values(uri, property_key, path)
      predicate_s = MuSearch::SPARQL.make_predicate_string(path)
      prop_key_s = property_key.gsub(/[^a-zA-Z1-9]/, "")
      query = <<SPARQL
    SELECT DISTINCT ?#{prop_key_s} WHERE {
      #{SinatraTemplate::Utils.sparql_escape_uri(uri)} #{predicate_s} ?#{prop_key_s}
    }
SPARQL
      results = @sparql_client.query(query)
      results.collect { |result| result[prop_key_s] }
    end

    # Get the array of values to index for a given SPARQL result set of simple values.
    # Values are constructed based on the literal datatype.
    def build_simple_property(values)
      values.collect do |value|
        case value
        when RDF::Literal::Integer
          value.to_i
        when RDF::Literal::Double
          value.to_f
        when RDF::Literal::Decimal
          value.to_f
        when RDF::Literal::Boolean
          value.true?
        when RDF::Literal::Time
          value.to_s
        when RDF::Literal::Date
          value.to_s
        when RDF::Literal::DateTime
          value.to_s
        when RDF::Literal
          value.to_s
        else
          value.to_s
        end
      end
    end

    # Get the array of objects to be indexed for a given SPARQL result set
    # of related resources configured to be indexed as nested object.
    # The properties to be indexed for the nested object are passed as an argument.
    def build_nested_object(related_resources, nested_properties)
      related_resources.collect do |resource_uri|
        nested_document = fetch_document_to_index(uri: resource_uri, properties: nested_properties)
        nested_document.merge({ uri: resource_uri })
      end
    end

    # Get the array of file objects to be indexed for a given set of file URIs.
    #
    # The file object to index currently contains the following properties:
    # - content: text content of the file
    # This list may be extended with additional metadata in the future.
    def build_file_field(file_uris)
      file_uris.collect do |file_uri|
        file_path = File.join(@attachment_path_base, file_uri.to_s.sub("share://", ""))
        if File.exist?(file_path)
          file_size = File.size(file_path)
          if file_size < ENV["MAXIMUM_FILE_SIZE"].to_i
            content = extract_text_content(file_path)
          else
            @logger.warn("INDEXING") do
              "File #{file_path} (#{file_size} bytes) exceeds the allowed size of #{ENV['MAXIMUM_FILE_SIZE']} bytes. File content will not be indexed."
            end
            content = nil
          end
        else
          @logger.warn("INDEXING") { "File #{file_path} not found. File content will not be indexed." }
          content = nil
        end
        { content: content }
      end
    end

    # Extract the text content of the file at the given path using Tika.
    # Use a previously cached result if one is available.
    # On successfull processing, returns the extracted text content.
    # Otherwise, returns nil.
    #
    # Entries are cached using the file hash as key.
    def extract_text_content(file_path)
      begin
        file = File.open(file_path, "rb")
        blob = file.read
        file.close
        file_hash = Digest::SHA256.hexdigest blob
        cached_file_path = "#{@cache_path_base}#{file_hash}"
        if File.exists? cached_file_path
          text_content = File.open(cached_file_path, mode: "rb", encoding: 'utf-8') do |file|
            @logger.debug("TIKA") { "Using cached result #{cached_file_path} for file #{file_path}" }
            file.read
          end
        else
          text_content = @tika.extract_text file_path, blob
          if text_content.nil?
            @logger.info("TIKA") { "Received empty result from Tika for file #{file_path}. File content will not be indexed." }
            # write emtpy file to make cache hit on next run
            File.open(cached_file_path, "w") {}
          else
            @logger.debug("TIKA") { "Extracting text from #{file_path} and storing result in #{cached_file_path}" }
            File.open(cached_file_path, "w") do |file|
              file.puts text_content.force_encoding("utf-8").unicode_normalize
            end
          end
        end
        text_content
      rescue Errno::ENOENT, IOError => e
        @logger.warn("TIKA") { "Error reading file at #{file_path} to extract content. File content will not be indexed." }
        @logger.warn("TIKA") { e.full_message }
        nil
      rescue StandardError => e
        @logger.warn("TIKA") { "Failed to extract content of file #{file_path}. File content will not be indexed." }
        @logger.warn("TIKA") { e.full_message }
        nil
      end
    end

    # Utility function to denumerate the given array value.
    # I.e.
    # - returns nil if the given array is empty
    # - returns a single value if the given array only contains one element
    # - returns the array value if the given array contains mulitple elements
    def denumerate(value)
      case value.length
      when 0 then nil
      when 1 then value.first
      else value
      end
    end

    ##
    # select sub indexes matching the type(s) of the provided resource
    def relevant_sub_indexes_for(uri, composite_types)
      types = @sparql_client.query( "SELECT DISTINCT ?type WHERE { #{sparql_escape_uri(uri)} a ?type}").map{ |result| result["type"].to_s }
      composite_types.select{ |sub_definition| (sub_definition.related_rdf_types & types).length > 0 }
    end

    ##
    # smart_merge document
    def smart_merge(document_a, document_b)
      document_a.merge(document_b) do |key, a_val, b_val|
        if a_val.nil?
          b_val
        elsif b_val.nil?
          a_val
        elsif a_val.is_a?(Array) && b_val.is_a?(Array)
          a_val.concat(b_val).uniq
        elsif a_val.is_a?(Array) && (b_val.is_a?(String) || b_val.is_a?(Integer) || b_val.is_a?(Float))
          [*a_val, b_val].uniq
        elsif a_val.is_a?(Hash)
          # b_val must also be a hash
          smart_merge(a_val, b_val)
        elsif  b_val.is_a?(Array) && (b_val.is_a?(String) || b_val.is_a?(Integer) || b_val.is_a?(Float))
          # a_val can not be nil or an array, so must be a simple value
          [*b_val, a_val].uniq
        elsif (a_val.is_a?(String) || a_val.is_a?(Integer) || a_val.is_a?(Float)) &&
              (b_val.is_a?(String) || b_val.is_a?(Integer) || b_val.is_a?(Float))
          [a_val,b_val].uniq
        else
          raise "smart_merge: Invalid combo #{a_val.inspect} and #{b_val.inspect} can not be merged"
        end
      end
    end
  end
end
