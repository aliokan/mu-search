require_relative 'update_handler'

module MuSearch
  ##
  # the automatic update handler is a service that executes updates or deletes on indexes.
  # when a document needs to be udpated the handler will fetch the required information from the triplestore
  # and insert that data into the correct index
  # when a document needs to be deleted it will verify that the document no longer exists in the triplestore
  # and if so remove it from the index
  # this handler takes the configured allowed_groups of an index into account
  class AutomaticUpdateHandler < MuSearch::UpdateHandler

    ##
    # creates an automatic update handler
    def initialize(elastic_client:, tika_client:, type_definitions:, attachment_path_base:, **args)
      @client = elastic_client
      @type_definitions = type_definitions
      @attachment_path_base = attachment_path_base
      @tika_client = tika_client
      super(**args)
    end

    def handler(subject, index_types, type)
      if type == :update
        update_document_in_indexes({document_id: subject, index_types: index_types})
      else
        delete_document_from_indexes({document_id: subject, index_types: index_types})
      end
    end

    ##
    # Update all documents relating to a particular uri and a series of
    # types.
    #
    #   - document_id: String URI of the entity which needs an update.
    #   - index_types: Array of index types where the document needs to be updated
    def update_document_in_indexes(document_id:, index_types: [])
      index_types.each do |index_type|
        @logger.debug "Updating document #{document_id} for type #{index_type}"
        indexes = Indexes.instance.get_indexes(index_type)
        indexes.each do |key, index|
          allowed_groups = index[:allowed_groups]
          sparql_client = build_sparql_client(allowed_groups)
          document_builder = DocumentBuilder.new(
            tika_client: @tika_client,
            sparql_client: sparql_client,
            attachment_path_base: @attachment_path_base,
            logger: @logger
          )
          @logger.debug "Got allowed groups for updated_document_all_types #{allowed_groups}"
          rdf_type = @type_definitions.dig(index_type, "rdf_type")
          @logger.debug "Got RDF type for updated_document_all_types #{rdf_type}"
          if document_exists_for(sparql_client, document_id, rdf_type)
            @logger.debug "Our current index knows that #{document_id} is of type #{rdf_type} based on allowed groups #{allowed_groups}"
            properties = @type_definitions.dig(index_type, "properties")
            document = document_builder.fetch_document_to_index(uri: document_id, properties: properties)
            document_for_reporting = document.clone
            document_for_reporting["data"] = document_for_reporting["data"] ? document_for_reporting["data"].length : "none"
            @logger.debug "Fetched document to index is #{document_for_reporting}"
            @client.upsert_document index[:index], document_id, document
          else
            @logger.info "AUTOMATIC UPDATE: Not Authorized."
          end
        end
      end
    end

    ##
    # Deletes all documents relating to a particular uri and a series of types.
    #
    #   - document_id: String URI of the entity which needs changing.
    #   - index_types: Array of types for which the document needs updating.
    def delete_document_from_indexes(document_id: , index_types: [])
      index_types.each do |index_type|
        @logger.debug "Deleting document #{document_id} for index type #{index_type}"
        indexes = Indexes.instance.get_indexes(index_type)
        indexes.each do |key, index|
          allowed_groups = index[:allowed_groups]
          sparql_client = build_sparql_client(allowed_groups)
          type = @type_definitions.dig(index_type, "rdf_type")
          if document_exists_for(sparql_client, document_id, type)
            @logger.debug "Not deleting document #{document_id} from #{index[:index]}, it still exists"
          else
            @logger.debug "Deleting document #{document_id} from #{index[:index]}"
            begin
              @client.delete_document index[:index], document_id
            rescue
              @logger.info "Failed to delete document: #{document_id} in index: #{index[:index]}"
            end
          end
        end
      end
    end

    private
    def build_sparql_client(allowed_groups)
      allowed_groups_object = allowed_groups.select { |group| group }
      sparql_options = { headers: { 'mu-auth-allowed-groups': allowed_groups_object.to_json } }
      ::SPARQL::Client.new(ENV['MU_SPARQL_ENDPOINT'], sparql_options)
    end
  end
end
