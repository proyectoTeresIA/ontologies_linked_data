module LinkedData
  module Models
    module OntoLex
      class Form < LinkedData::Models::Base
        model :form, name_with: :id, collection: :submission,
                     namespace: :ontolex, schemaless: :true,
                     rdf_type: ->(*_x) { RDF::URI("http://www.w3.org/ns/lemon/ontolex#Form") }

        attribute :writtenRep, namespace: :ontolex
        attribute :language, namespace: :dcterms
        attribute :gender, namespace: :lexinfo, property: :gender
        attribute :number, namespace: :lexinfo, property: :number
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        serialize_default :writtenRep, :gender, :number
        serialize_never :submission
        serialize_methods :properties, :computed

        link_to LinkedData::Hypermedia::Link.new("self", ->(s) { "ontologies/#{s.submission.ontology.acronym}/forms/#{CGI.escape(s.id.to_s)}" }, self.uri_type)

        def properties
          self.unmapped
        end

        # Ensure default attributes populate even for read_only instances
        def ensure_computed
          return if defined?(@_computed_populated) && @_computed_populated
          data = computed
          if data && data.is_a?(Hash)
            self.writtenRep = Array(data[:writtenRep]) if data.key?(:writtenRep)
            # do not set language at Form level
            self.gender = data[:gender] if data.key?(:gender)
            self.number = data[:number] if data.key?(:number)
          end
          @_computed_populated = true
        end

        def writtenRep
          val = instance_variable_defined?(:@writtenRep) ? instance_variable_get(:@writtenRep) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            ensure_computed
            val = instance_variable_defined?(:@writtenRep) ? instance_variable_get(:@writtenRep) : val
          end
          return [] if val.nil?
          val.is_a?(Array) ? val : [val]
        end

        def gender
          val = instance_variable_defined?(:@gender) ? instance_variable_get(:@gender) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            ensure_computed
            val = instance_variable_defined?(:@gender) ? instance_variable_get(:@gender) : val
          end
          return [] if val.nil?
          val.is_a?(Array) ? val : [val]
        end

        def number
          val = instance_variable_defined?(:@number) ? instance_variable_get(:@number) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            ensure_computed
            val = instance_variable_defined?(:@number) ? instance_variable_get(:@number) : val
          end
          return [] if val.nil?
          val.is_a?(Array) ? val : [val]
        end

        # Ensure computed fields are populated prior to serialization
        def to_hash(options = {})
          begin
            ensure_computed
          rescue StandardError
          end
          h = super(options)
          # Force-populate keys with computed getters to avoid empty arrays from Goo masking values
          h["writtenRep"] = self.writtenRep if self.respond_to?(:writtenRep)
          # We don't infer language on forms; include only if explicitly present
          h["language"] = self.language if self.respond_to?(:language) && !self.language.nil?
          h["gender"] = self.gender if self.respond_to?(:gender)
          h["number"] = self.number if self.respond_to?(:number)
          h
        end

        def computed
          return {} unless self.submission && self.id
          graph = self.submission.id
          fid = self.id
          wr_p = "http://www.w3.org/ns/lemon/ontolex#writtenRep"
          wr_p_lemon = "http://lemon-model.net/lemon#writtenRep"
          lang_p = "http://purl.org/dc/terms/language"
          g_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#gender"
          g_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#gender"
          g_20 = "http://lexinfo.net/ontology/2.0/lexinfo#gender"
          n_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#number"
          n_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#number"
          n_20 = "http://lexinfo.net/ontology/2.0/lexinfo#number"
          qry = [
            "SELECT ?p ?o WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{fid}> }",
            "    ?s ?p ?o .",
            "    FILTER(?p IN (<#{wr_p}>, <#{wr_p_lemon}>, <#{lang_p}>, <#{g_http}>, <#{g_https}>, <#{g_20}>, <#{n_http}>, <#{n_https}>, <#{n_20}>))",
            "  }",
            "}",
          ].join("\n")
          epr = Goo.sparql_query_client(:main)
          result = {}
          begin
            epr.query(qry, graphs: [graph]).each do |row|
              case row[:p].to_s
              when wr_p, wr_p_lemon
                (result[:writtenRep] ||= []) << row[:o].to_s
              when lang_p
                (result[:language] ||= []) << row[:o].to_s
              when g_http, g_https, g_20
                (result[:gender] ||= []) << row[:o].to_s
              when n_http, n_https, n_20
                (result[:number] ||= []) << row[:o].to_s
              end
            end
          rescue StandardError
          end
          [:writtenRep, :gender, :number].each do |k|
            result[k] = result[k].uniq if result[k].respond_to?(:uniq!)
          end
          result
        end

        # Build enriched read_only Forms for specific IRIs (parity with list endpoint)
        def self.list_for_ids(submission, ids, _include_attrs = [])
          return [] unless submission && ids && !ids.empty?
          graph = submission.id
          wr_p = "http://www.w3.org/ns/lemon/ontolex#writtenRep"
          wr_p_lemon = "http://lemon-model.net/lemon#writtenRep"
          lang_p = "http://purl.org/dc/terms/language"
          g_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#gender"
          g_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#gender"
          g_20 = "http://lexinfo.net/ontology/2.0/lexinfo#gender"
          n_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#number"
          n_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#number"
          n_20 = "http://lexinfo.net/ontology/2.0/lexinfo#number"
          ids.map do |fid|
            fid = fid.to_s
            next nil if fid.empty?
            qf = [
              "SELECT ?p ?o WHERE {",
              "  GRAPH <#{graph}> {",
              "    VALUES ?s { <#{fid}> }",
              "    ?s ?p ?o .",
              "    FILTER(?p IN (<#{wr_p}>, <#{wr_p_lemon}>, <#{lang_p}>, <#{g_http}>, <#{g_https}>, <#{g_20}>, <#{n_http}>, <#{n_https}>, <#{n_20}>))",
              "  }",
              "}",
            ].join("\n")
            attrs = { id: RDF::URI(fid), submission: submission, writtenRep: [] }
            begin
              Goo.sparql_query_client(:main).query(qf, graphs: [graph]).each do |row|
                case row[:p].to_s
                when wr_p, wr_p_lemon
                  (attrs[:writtenRep] ||= []) << row[:o].to_s
                when lang_p
                  # not exposing language by default
                when g_http, g_https, g_20
                  (attrs[:gender] ||= []) << row[:o].to_s
                when n_http, n_https, n_20
                  (attrs[:number] ||= []) << row[:o].to_s
                end
              end
            rescue StandardError
            end
            [:writtenRep, :gender, :number].each do |k|
              arr = attrs[k]
              attrs[k] = arr.uniq if arr.respond_to?(:uniq!)
            end
            LinkedData::Models::OntoLex::Form.read_only(attrs)
          end.compact
        end

        def self.list_in_submission(submission, page, size, _include_attrs = [])
          return [] unless submission
          graph = submission.id
          offset = (page - 1) * size
          type_uri = "http://www.w3.org/ns/lemon/ontolex#Form"
          l_type_uri = "http://lemon-model.net/lemon#Form"
          wr_p = "http://www.w3.org/ns/lemon/ontolex#writtenRep"
          wr_p_lemon = "http://lemon-model.net/lemon#writtenRep"
          
          # Simplified query - only select Form types
          q = [
            "SELECT DISTINCT ?f WHERE {",
            "  GRAPH <#{graph}> {",
            "    { ?f a <#{type_uri}> } UNION { ?f a <#{l_type_uri}> }",
            "    FILTER(isIRI(?f))",
            "  }",
            "} ORDER BY ?f LIMIT #{size} OFFSET #{offset}",
          ].join("\n")
          
          epr = Goo.sparql_query_client(:main)
          rows = []
          begin
            rows = epr.query(q, graphs: [graph])
          rescue StandardError
            rows = []
          end
          return [] if rows.empty?
          
          # Batch query for all form properties
          ids = rows.map { |row| row[:f].to_s }.select { |s| !s.empty? }
          return [] if ids.empty?
          
          lang_p = "http://purl.org/dc/terms/language"
          g_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#gender"
          g_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#gender"
          g_20 = "http://lexinfo.net/ontology/2.0/lexinfo#gender"
          n_http = "http://www.lexinfo.net/ontology/3.0/lexinfo#number"
          n_https = "https://www.lexinfo.net/ontology/3.0/lexinfo#number"
          n_20 = "http://lexinfo.net/ontology/2.0/lexinfo#number"
          
          values = ids.map { |id| "<#{id}>" }.join(" ")
          batch_q = [
            "SELECT ?f ?p ?o WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?f { #{values} }",
            "    ?f ?p ?o .",
            "    FILTER(?p IN (<#{wr_p}>, <#{wr_p_lemon}>, <#{lang_p}>, <#{g_http}>, <#{g_https}>, <#{g_20}>, <#{n_http}>, <#{n_https}>, <#{n_20}>))",
            "  }",
            "}",
          ].join("\n")
          
          # Collect results by form ID
          form_attrs = {}
          ids.each { |id| form_attrs[id] = { id: RDF::URI(id), submission: submission, writtenRep: [] } }
          
          begin
            epr.query(batch_q, graphs: [graph]).each do |row|
              fid = row[:f].to_s
              next unless form_attrs[fid]
              
              case row[:p].to_s
              when wr_p, wr_p_lemon
                form_attrs[fid][:writtenRep] << row[:o].to_s
              when g_http, g_https, g_20
                (form_attrs[fid][:gender] ||= []) << row[:o].to_s
              when n_http, n_https, n_20
                (form_attrs[fid][:number] ||= []) << row[:o].to_s
              end
            end
          rescue StandardError
          end
          
          # Dedup and create read_only objects
          form_attrs.values.map do |attrs|
            [:writtenRep, :gender, :number].each do |k|
              arr = attrs[k]
              attrs[k] = arr.uniq if arr.respond_to?(:uniq)
            end
            LinkedData::Models::OntoLex::Form.read_only(attrs)
          end
        end

        def self.count_in_submission(submission)
          return 0 unless submission
          graph = submission.id
          entry_type = "http://www.w3.org/ns/lemon/ontolex#LexicalEntry"
          form_p = "http://www.w3.org/ns/lemon/ontolex#form"
          lex_form_p = "http://www.w3.org/ns/lemon/ontolex#lexicalForm"
          can_p = "http://www.w3.org/ns/lemon/ontolex#canonicalForm"
          oth_p = "http://www.w3.org/ns/lemon/ontolex#otherForm"
          l_form_p = "http://lemon-model.net/lemon#form"
          l_can_p = "http://lemon-model.net/lemon#canonicalForm"
          l_oth_p = "http://lemon-model.net/lemon#otherForm"
          type_uri = "http://www.w3.org/ns/lemon/ontolex#Form"
          l_type_uri = "http://lemon-model.net/lemon#Form"
          epr = Goo.sparql_query_client(:main)
          begin
            q = [
              "SELECT (COUNT(DISTINCT ?f) AS ?count) WHERE {",
              "  GRAPH <#{graph}> {",
              "    { ?e a <#{entry_type}> . ?e (<#{form_p}>|<#{lex_form_p}>|<#{can_p}>|<#{oth_p}>|<#{l_form_p}>|<#{l_can_p}>|<#{l_oth_p}>) ?f }",
              "    UNION { ?f a <#{type_uri}> }",
              "    UNION { ?f a <#{l_type_uri}> }",
              "    FILTER(isIRI(?f))",
              "  }",
              "}",
            ].join("\n")
            row = epr.query(q, graphs: [graph]).first
            (row && row[:count]) ? row[:count].to_s.to_i : 0
          rescue StandardError
            0
          end
        end
      end
    end
  end
end
