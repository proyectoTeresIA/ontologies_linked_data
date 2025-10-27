module LinkedData
  module Models
    module OntoLex
      class LexicalSense < LinkedData::Models::Base
        model :lexical_sense, name_with: :id, collection: :submission,
                              namespace: :ontolex, schemaless: :true,
                              rdf_type: ->(*_x) { RDF::URI("http://www.w3.org/ns/lemon/ontolex#LexicalSense") }

        attribute :definition, namespace: :dcterms
        attribute :example, namespace: :dcterms, property: :example
        attribute :reference, namespace: :ontolex
        attribute :synonym, namespace: :lexinfo, property: :synonym
        attribute :translation, namespace: :vartrans, property: :translation
        attribute :normativeAuthorization, namespace: :lexinfo, property: :normativeAuthorization
        attribute :usageExample, namespace: :lexicog, property: :usageExample
        attribute :reliabilityCode, namespace: :termlex, property: :reliabilityCode
        attribute :usage, namespace: :termlex, property: :usage
        attribute :isSenseOf, namespace: :ontolex, range: -> { LinkedData::Models::OntoLex::LexicalEntry }
        attribute :lexicalConcept, namespace: :ontolex, property: :isLexicalizedSenseOf, range: -> { LinkedData::Models::OntoLex::LexicalConcept }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        do_not_load :isSenseOf
        serialize_default :definition, :example, :reference, :lexicalConcept, :synonym, :translation, :normativeAuthorization, :usageExample, :reliabilityCode, :usage
        serialize_never :submission
        serialize_methods :properties, :computed
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new("self", ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_senses/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new("ontology", ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary["Ontology"])

        def properties
          self.unmapped
        end

        # Lazy compute and cache scalar fields to ensure defaults serialize
        def ensure_computed
          return if defined?(@_computed_populated) && @_computed_populated
          data = computed
          if data && data.is_a?(Hash)
            self.definition = data[:definition] if data.key?(:definition)
            self.example = data[:example] if data.key?(:example)
            self.reference = data[:reference] if data.key?(:reference)
            self.synonym = data[:synonym] if data.key?(:synonym)
            self.translation = data[:translation] if data.key?(:translation)
            self.normativeAuthorization = data[:normativeAuthorization] if data.key?(:normativeAuthorization)
            self.usageExample = data[:usageExample] if data.key?(:usageExample)
            self.reliabilityCode = data[:reliabilityCode] if data.key?(:reliabilityCode)
            self.usage = data[:usage] if data.key?(:usage)
            # Provide lexicalConcept as plain URIs when available
            if data.key?(:lexicalConcept)
              lc_vals = Array(data[:lexicalConcept])
              # Store as plain string IRIs to keep JSON serialization simple and robust
              self.lexicalConcept = lc_vals.map { |iri| iri.to_s }
            end
          end
          @_computed_populated = true
        end

        # Ensure scalar fields are available even if not eager-loaded via Goo
        def computed
          return {} unless self.submission && self.id
          graph = self.submission.id
          sid = self.id
          def_p = "http://purl.org/dc/terms/definition"
          def_p2 = "http://purl.org/dc/terms/description"
          def_p3 = "http://www.w3.org/2004/02/skos/core#definition"
          def_p4 = "http://www.w3.org/2000/01/rdf-schema#comment"
          ex_p = "http://purl.org/dc/terms/example"
          ref_p = "http://www.w3.org/ns/lemon/ontolex#reference"
          syn_p = "http://www.lexinfo.net/ontology/3.0/lexinfo#synonym"
          syn_p2 = "http://lexinfo.net/ontology/2.0/lexinfo#synonym"
          tr_p = "http://www.w3.org/ns/lemon/vartrans#translation"
          na_p = "http://www.lexinfo.net/ontology/3.0/lexinfo#normativeAuthorization"
          na_p2 = "http://lexinfo.net/ontology/2.0/lexinfo#normativeAuthorization"
          ue_p = "http://www.w3.org/ns/lemon/lime#usageExample"
          # Some datasets use lexicog for usageExample; keep lexicog prefix per request
          ue_p2 = "https://www.w3.org/ns/lemon/lexicog#usageExample"
          ue_p3 = "http://www.w3.org/ns/lemon/lexicog#usageExample"
          rc_p = "https://termlex.oeg.fi.upm.es/termlex/reliabilityCode"
          rc_p2 = "http://termlex.oeg.fi.upm.es/termlex/reliabilityCode"
          usg_p = "https://termlex.oeg.fi.upm.es/termlex/usage"
          usg_p2 = "http://termlex.oeg.fi.upm.es/termlex/usage"
          lc_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          lc_inv_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          qry = [
            "SELECT DISTINCT ?p ?o WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{sid}> }",
            "    {",
            "      ?s ?p ?o .",
            "      FILTER(?p IN (<#{def_p}>, <#{def_p2}>, <#{def_p3}>, <#{def_p4}>, <#{ex_p}>, <#{ref_p}>, <#{syn_p}>, <#{syn_p2}>, <#{tr_p}>, <#{na_p}>, <#{na_p2}>, <#{ue_p}>, <#{ue_p2}>, <#{ue_p3}>, <#{rc_p}>, <#{rc_p2}>, <#{usg_p}>, <#{usg_p2}>, <#{lc_p}>))",
            "    } UNION {",
            "      ?c <#{lc_inv_p}> ?s .",
            "      BIND(<#{lc_p}> AS ?p)",
            "      BIND(?c AS ?o)",
            "    }",
            "  }",
            "}",
          ].join("\n")
          epr = Goo.sparql_query_client(:main)
          result = {}
          begin
            epr.query(qry, graphs: [graph]).each do |row|
              case row[:p].to_s
              when def_p, def_p2, def_p3, def_p4
                (result[:definition] ||= []) << row[:o].to_s
              when ex_p
                (result[:example] ||= []) << row[:o].to_s
              when ref_p
                (result[:reference] ||= []) << row[:o].to_s
              when syn_p, syn_p2
                (result[:synonym] ||= []) << row[:o].to_s
              when tr_p
                (result[:translation] ||= []) << row[:o].to_s
              when na_p, na_p2
                (result[:normativeAuthorization] ||= []) << row[:o].to_s
              when ue_p, ue_p2, ue_p3
                (result[:usageExample] ||= []) << row[:o].to_s
              when rc_p, rc_p2
                (result[:reliabilityCode] ||= []) << row[:o].to_s
              when usg_p, usg_p2
                (result[:usage] ||= []) << row[:o].to_s
              when lc_p
                (result[:lexicalConcept] ||= []) << row[:o].to_s
              end
            end
          rescue StandardError
          end
          [:definition, :example, :reference, :lexicalConcept, :synonym, :translation, :normativeAuthorization, :usageExample, :reliabilityCode, :usage].each do |k|
            result[k] = result[k].uniq if result[k].respond_to?(:uniq!)
          end
          result
        end

        # Override getters to compute on-demand when empty
        def definition
          val = instance_variable_defined?(:@definition) ? instance_variable_get(:@definition) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            ensure_computed
            val = instance_variable_defined?(:@definition) ? instance_variable_get(:@definition) : val
          end
          val
        end

        def example
          val = instance_variable_defined?(:@example) ? instance_variable_get(:@example) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            ensure_computed
            val = instance_variable_defined?(:@example) ? instance_variable_get(:@example) : val
          end
          val
        end

        def reference
          val = instance_variable_defined?(:@reference) ? instance_variable_get(:@reference) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            ensure_computed
            val = instance_variable_defined?(:@reference) ? instance_variable_get(:@reference) : val
          end
          val
        end

        def lexicalConcept
          val = instance_variable_defined?(:@lexicalConcept) ? instance_variable_get(:@lexicalConcept) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            ensure_computed
            val = instance_variable_defined?(:@lexicalConcept) ? instance_variable_get(:@lexicalConcept) : val
          end
          # Normalize to array; never return nil so serializers keep the key
          return [] if val.nil?
          val
        end

        # Ensure computed fields are populated before serialization
        def to_hash(options = {})
          begin
            ensure_computed
          rescue StandardError
          end
          h = super(options)
          h["definition"] ||= (self.definition || []) if self.respond_to?(:definition)
          h["example"] ||= (self.example || []) if self.respond_to?(:example)
          h["reference"] ||= (self.reference || []) if self.respond_to?(:reference)
          h["synonym"] ||= (self.synonym || []) if self.respond_to?(:synonym)
          h["translation"] ||= (self.translation || []) if self.respond_to?(:translation)
          h["normativeAuthorization"] ||= (self.normativeAuthorization || []) if self.respond_to?(:normativeAuthorization)
          h["usageExample"] ||= (self.usageExample || []) if self.respond_to?(:usageExample)
          h["reliabilityCode"] ||= (self.reliabilityCode || []) if self.respond_to?(:reliabilityCode)
          h["usage"] ||= (self.usage || []) if self.respond_to?(:usage)
          if self.respond_to?(:lexicalConcept)
            lc = self.lexicalConcept
            # Only set if missing; preserve pre-populated values from read_only_enriched/show_enriched
            h["lexicalConcept"] ||= (lc || [])
          end
          h
        end

        def self.list_in_submission(submission, page, size, _include_attrs = [])
          return [] unless submission
          graph = submission.id
          offset = (page - 1) * size
          sense_type = "http://www.w3.org/ns/lemon/ontolex#LexicalSense"
          
          # Simplified query - only select LexicalSense types
          q = [
            "SELECT DISTINCT ?s WHERE {",
            "  GRAPH <#{graph}> {",
            "    ?s a <#{sense_type}> .",
            "    FILTER(isIRI(?s))",
            "  }",
            "} ORDER BY ?s LIMIT #{size} OFFSET #{offset}",
          ].join("\n")
          
          epr = Goo.sparql_query_client(:main)
          rows = []
          begin
            rows = epr.query(q, graphs: [graph])
          rescue StandardError
            rows = []
          end
          ids = rows.map { |row| row[:s].to_s }.select { |s| !s.to_s.empty? }
          return [] if ids.empty?
          
          # Batch query for all sense properties
          def_p = "http://purl.org/dc/terms/definition"
          def_p2 = "http://purl.org/dc/terms/description"
          def_p3 = "http://www.w3.org/2004/02/skos/core#definition"
          def_p4 = "http://www.w3.org/2000/01/rdf-schema#comment"
          ex_p = "http://purl.org/dc/terms/example"
          ref_p = "http://www.w3.org/ns/lemon/ontolex#reference"
          syn_p = "http://www.lexinfo.net/ontology/3.0/lexinfo#synonym"
          syn_p2 = "http://lexinfo.net/ontology/2.0/lexinfo#synonym"
          tr_p = "http://www.w3.org/ns/lemon/vartrans#translation"
          na_p = "http://www.lexinfo.net/ontology/3.0/lexinfo#normativeAuthorization"
          na_p2 = "http://lexinfo.net/ontology/2.0/lexinfo#normativeAuthorization"
          ue_p = "http://www.w3.org/ns/lemon/lime#usageExample"
          ue_p2 = "https://www.w3.org/ns/lemon/lexicog#usageExample"
          ue_p3 = "http://www.w3.org/ns/lemon/lexicog#usageExample"
          rc_p = "https://termlex.oeg.fi.upm.es/termlex/reliabilityCode"
          rc_p2 = "http://termlex.oeg.fi.upm.es/termlex/reliabilityCode"
          usg_p = "https://termlex.oeg.fi.upm.es/termlex/usage"
          usg_p2 = "http://termlex.oeg.fi.upm.es/termlex/usage"
          lc_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          lc_inv_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          
          values = ids.map { |id| "<#{id}>" }.join(" ")
          batch_q = [
            "SELECT ?s ?p ?o WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { #{values} }",
            "    {",
            "      ?s ?p ?o .",
            "      FILTER(?p IN (<#{def_p}>, <#{def_p2}>, <#{def_p3}>, <#{def_p4}>, <#{ex_p}>, <#{ref_p}>, <#{syn_p}>, <#{syn_p2}>, <#{tr_p}>, <#{na_p}>, <#{na_p2}>, <#{ue_p}>, <#{ue_p2}>, <#{ue_p3}>, <#{rc_p}>, <#{rc_p2}>, <#{usg_p}>, <#{usg_p2}>, <#{lc_p}>))",
            "    } UNION {",
            "      ?c <#{lc_inv_p}> ?s .",
            "      BIND(<#{lc_p}> AS ?p)",
            "      BIND(?c AS ?o)",
            "    }",
            "  }",
            "}",
          ].join("\n")
          
          # Collect results by sense ID
          sense_attrs = {}
          ids.each { |id| sense_attrs[id] = { id: RDF::URI(id), submission: submission } }
          
          begin
            epr.query(batch_q, graphs: [graph]).each do |row|
              sid = row[:s].to_s
              next unless sense_attrs[sid]
              
              case row[:p].to_s
              when def_p, def_p2, def_p3, def_p4
                (sense_attrs[sid][:definition] ||= []) << row[:o].to_s
              when ex_p
                (sense_attrs[sid][:example] ||= []) << row[:o].to_s
              when ref_p
                (sense_attrs[sid][:reference] ||= []) << row[:o].to_s
              when syn_p, syn_p2
                (sense_attrs[sid][:synonym] ||= []) << row[:o].to_s
              when tr_p
                (sense_attrs[sid][:translation] ||= []) << row[:o].to_s
              when na_p, na_p2
                (sense_attrs[sid][:normativeAuthorization] ||= []) << row[:o].to_s
              when ue_p, ue_p2, ue_p3
                (sense_attrs[sid][:usageExample] ||= []) << row[:o].to_s
              when rc_p, rc_p2
                (sense_attrs[sid][:reliabilityCode] ||= []) << row[:o].to_s
              when usg_p, usg_p2
                (sense_attrs[sid][:usage] ||= []) << row[:o].to_s
              when lc_p
                (sense_attrs[sid][:lexicalConcept] ||= []) << row[:o].to_s
              end
            end
          rescue StandardError
          end
          
          # Dedup and create read_only objects
          sense_attrs.values.map do |attrs|
            [:definition, :example, :reference, :lexicalConcept, :synonym, :translation, :normativeAuthorization, :usageExample, :reliabilityCode, :usage].each do |k|
              arr = attrs[k]
              attrs[k] = arr.uniq if arr.respond_to?(:uniq)
            end
            LinkedData::Models::OntoLex::LexicalSense.read_only(attrs)
          end
        end
        def self.count_in_submission(submission)
          return 0 unless submission
          graph = submission.id
          entry_type = "http://www.w3.org/ns/lemon/ontolex#LexicalEntry"
          sense_type = "http://www.w3.org/ns/lemon/ontolex#LexicalSense"
          sense_p = "http://www.w3.org/ns/lemon/ontolex#sense"
          isSenseOf_p = "http://www.w3.org/ns/lemon/ontolex#isSenseOf"
          lex_sense_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          epr = Goo.sparql_query_client(:main)
          begin
            q = [
              "SELECT (COUNT(DISTINCT ?s) AS ?count) WHERE {",
              "  GRAPH <#{graph}> {",
              "    { ?e a <#{entry_type}> . { ?e <#{sense_p}> ?s } UNION { ?s <#{isSenseOf_p}> ?e } }",
              "    UNION { ?s a <#{sense_type}> }",
              "    UNION { ?lc <#{lex_sense_p}> ?s }",
              "    FILTER(isIRI(?s))",
              "  }",
              "}",
            ].join("\n")
            row = epr.query(q, graphs: [graph]).first
            (row && row[:count]) ? row[:count].to_s.to_i : 0
          rescue StandardError
            0
          end
        end

        # Build enriched read_only senses for specific IRIs (used by show endpoint)
        def self.list_for_ids(submission, ids, _include_attrs = [])
          return [] unless submission && ids && !ids.empty?
          graph = submission.id
          ids.map do |sid|
            sid = sid.to_s
            next nil if sid.empty?
            def_p = "http://purl.org/dc/terms/definition"
            def_p2 = "http://purl.org/dc/terms/description"
            def_p3 = "http://www.w3.org/2004/02/skos/core#definition"
            def_p4 = "http://www.w3.org/2000/01/rdf-schema#comment"
            ex_p = "http://purl.org/dc/terms/example"
            ref_p = "http://www.w3.org/ns/lemon/ontolex#reference"
            syn_p = "http://www.lexinfo.net/ontology/3.0/lexinfo#synonym"
            syn_p2 = "http://lexinfo.net/ontology/2.0/lexinfo#synonym"
            tr_p = "http://www.w3.org/ns/lemon/vartrans#translation"
            na_p = "http://www.lexinfo.net/ontology/3.0/lexinfo#normativeAuthorization"
            na_p2 = "http://lexinfo.net/ontology/2.0/lexinfo#normativeAuthorization"
            ue_p = "http://www.w3.org/ns/lemon/lime#usageExample"
            ue_p2 = "https://www.w3.org/ns/lemon/lexicog#usageExample"
            ue_p3 = "http://www.w3.org/ns/lemon/lexicog#usageExample"
            rc_p = "https://termlex.oeg.fi.upm.es/termlex/reliabilityCode"
            rc_p2 = "http://termlex.oeg.fi.upm.es/termlex/reliabilityCode"
            usg_p = "https://termlex.oeg.fi.upm.es/termlex/usage"
            usg_p2 = "http://termlex.oeg.fi.upm.es/termlex/usage"
            lc_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
            lc_inv_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
            qs = [
              "SELECT DISTINCT ?p ?o WHERE {",
              "  GRAPH <#{graph}> {",
              "    VALUES ?s { <#{sid}> }",
              "    {",
              "      ?s ?p ?o .",
              "      FILTER(?p IN (<#{def_p}>, <#{def_p2}>, <#{def_p3}>, <#{def_p4}>, <#{ex_p}>, <#{ref_p}>, <#{syn_p}>, <#{syn_p2}>, <#{tr_p}>, <#{na_p}>, <#{na_p2}>, <#{ue_p}>, <#{ue_p2}>, <#{ue_p3}>, <#{rc_p}>, <#{rc_p2}>, <#{usg_p}>, <#{usg_p2}>, <#{lc_p}>))",
              "    } UNION {",
              "      ?c <#{lc_inv_p}> ?s .",
              "      BIND(<#{lc_p}> AS ?p)",
              "      BIND(?c AS ?o)",
              "    }",
              "  }",
              "}",
            ].join("\n")
            attrs = { id: RDF::URI(sid), submission: submission }
            begin
              Goo.sparql_query_client(:main).query(qs, graphs: [graph]).each do |row|
                case row[:p].to_s
                when def_p, def_p2, def_p3, def_p4
                  (attrs[:definition] ||= []) << row[:o].to_s
                when ex_p
                  (attrs[:example] ||= []) << row[:o].to_s
                when ref_p
                  (attrs[:reference] ||= []) << row[:o].to_s
                when syn_p, syn_p2
                  (attrs[:synonym] ||= []) << row[:o].to_s
                when tr_p
                  (attrs[:translation] ||= []) << row[:o].to_s
                when na_p, na_p2
                  (attrs[:normativeAuthorization] ||= []) << row[:o].to_s
                when ue_p, ue_p2, ue_p3
                  (attrs[:usageExample] ||= []) << row[:o].to_s
                when rc_p, rc_p2
                  (attrs[:reliabilityCode] ||= []) << row[:o].to_s
                when usg_p, usg_p2
                  (attrs[:usage] ||= []) << row[:o].to_s
                when lc_p
                  (attrs[:lexicalConcept] ||= []) << row[:o].to_s
                end
              end
            rescue StandardError
            end
            [:definition, :example, :reference, :lexicalConcept, :synonym, :translation, :normativeAuthorization, :usageExample, :reliabilityCode, :usage].each do |k|
              arr = attrs[k]
              attrs[k] = arr.uniq if arr.respond_to?(:uniq!)
            end
            LinkedData::Models::OntoLex::LexicalSense.read_only(attrs)
          end.compact
        end
      end
    end
  end
end
