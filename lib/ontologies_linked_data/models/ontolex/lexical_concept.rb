module LinkedData
  module Models
    module OntoLex
      class LexicalConcept < LinkedData::Models::Base
        model :lexical_concept, name_with: :id, collection: :submission,
                                namespace: :ontolex, schemaless: :true,
                                rdf_type: ->(*_x) { RDF::URI("http://www.w3.org/ns/lemon/ontolex#LexicalConcept") }

        attribute :definition, namespace: :skos, enforce: [:list]
        attribute :inScheme, namespace: :skos
        attribute :lexicalizedSense, namespace: :ontolex, property: :lexicalizedSense, range: -> { LinkedData::Models::OntoLex::LexicalSense }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        do_not_load :lexicalizedSense
        serialize_default :subject, :definition, :inScheme, :lexicalizedSense, :isEvokedBy
        serialize_never :submission
        serialize_methods :properties
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new("self", ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_concepts/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new("ontology", ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary["Ontology"])

        def properties
          self.unmapped
        end

        # Expose the concept IRI as 'subject'
        def subject
          # Return subject as a structured object with broader/narrower/prefLabel if available
          return self.id.to_s unless self.submission && self.id
          
          graph = self.submission.id
          cid = self.id
          
          # First check if there's a dct:subject pointing to a SKOS Concept
          subj_p = "http://purl.org/dc/terms/subject"
          
          q = [
            "SELECT ?subj WHERE {",
            "  GRAPH <#{graph}> {",
            "    <#{cid}> <#{subj_p}> ?subj .",
            "  }",
            "} LIMIT 1",
          ].join("\n")
          
          epr = Goo.sparql_query_client(:main)
          subj_uri = nil
          begin
            row = epr.query(q, graphs: [graph]).first
            subj_uri = row[:subj].to_s if row
          rescue StandardError
          end
          
          # If we have a subject, fetch its properties (broader, narrower, prefLabel, isTopConceptOf)
          if subj_uri && !subj_uri.empty?
            bro_p = "http://www.w3.org/2004/02/skos/core#broader"
            nar_p = "http://www.w3.org/2004/02/skos/core#narrower"
            pref_p = "http://www.w3.org/2004/02/skos/core#prefLabel"
            top_p = "http://www.w3.org/2004/02/skos/core#topConceptOf"
            
            q2 = [
              "SELECT ?p ?o WHERE {",
              "  GRAPH <#{graph}> {",
              "    <#{subj_uri}> ?p ?o .",
              "    FILTER(?p IN (<#{bro_p}>, <#{nar_p}>, <#{pref_p}>, <#{top_p}>))",
              "  }",
              "}",
            ].join("\n")
            
            result = { "@id" => subj_uri }
            begin
              epr.query(q2, graphs: [graph]).each do |row|
                case row[:p].to_s
                when bro_p
                  (result["broader"] ||= []) << row[:o].to_s
                when nar_p
                  (result["narrower"] ||= []) << row[:o].to_s
                when pref_p
                  (result["prefLabel"] ||= []) << row[:o].to_s
                when top_p
                  (result["isTopConceptOf"] ||= []) << row[:o].to_s
                end
              end
            rescue StandardError
            end
            
            result
          else
            # No dct:subject, just return the concept IRI as a string
            cid.to_s
          end
        end

        # Compute essential scalar attributes to avoid missing values when nested loads are restricted
        def computed
          return {} unless self.submission && self.id
          graph = self.submission.id
          cid = self.id
          def_p = "http://www.w3.org/2004/02/skos/core#definition"
          ins_p = "http://www.w3.org/2004/02/skos/core#inScheme"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          ls_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          ls_inv_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          
          qry = [
            "SELECT ?p ?o WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{cid}> }",
            "    {",
            "      ?s ?p ?o .",
            "      FILTER(?p IN (<#{def_p}>, <#{ins_p}>, <#{ls_p}>))",
            "    } UNION {",
            "      ?ls <#{ls_inv_p}> ?s .",
            "      BIND(<#{ls_p}> AS ?p)",
            "      BIND(?ls AS ?o)",
            "    } UNION {",
            "      ?e <#{evokes_p}> ?s .",
            "      BIND(<http://www.w3.org/ns/lemon/ontolex#isEvokedBy> AS ?p)",
            "      BIND(?e AS ?o)",
            "    }",
            "  }",
            "}",
          ].join("\n")
          
          epr = Goo.sparql_query_client(:main)
          result = {}
          begin
            epr.query(qry, graphs: [graph]).each do |row|
              pred = row[:p].to_s
              obj = row[:o]
              case pred
              when def_p
                # Definition is a resource, fetch its properties
                (result["definition"] ||= []) << obj.to_s
              when ins_p
                (result["inScheme"] ||= []) << obj.to_s
              when ls_p
                (result["lexicalizedSense"] ||= []) << obj.to_s
              when "http://www.w3.org/ns/lemon/ontolex#isEvokedBy"
                (result["isEvokedBy"] ||= []) << obj.to_s
              end
            end
          rescue StandardError
          end
          
          # Now resolve definition resources to get their language and label
          if result["definition"] && result["definition"].is_a?(Array)
            def_uris = result["definition"]
            resolved_defs = []
            lang_p = "http://purl.org/dc/terms/language"
            rdfs_label = "http://www.w3.org/2000/01/rdf-schema#label"
            
            def_uris.each do |def_uri|
              def_q = [
                "SELECT ?lang ?label WHERE {",
                "  GRAPH <#{graph}> {",
                "    <#{def_uri}> <#{lang_p}> ?lang .",
                "    OPTIONAL { <#{def_uri}> <#{rdfs_label}> ?label }",
                "  }",
                "}",
              ].join("\n")
              
              begin
                row = epr.query(def_q, graphs: [graph]).first
                if row
                  resolved_defs << {
                    "id" => def_uri,
                    "language" => row[:lang] ? row[:lang].to_s : nil,
                    "label" => row[:label] ? row[:label].to_s : nil
                  }
                else
                  # Fallback: just include the URI
                  resolved_defs << { "id" => def_uri }
                end
              rescue StandardError
                resolved_defs << { "id" => def_uri }
              end
            end
            
            result["definition"] = resolved_defs
          end
          
          # Dedup arrays
          %w[definition inScheme lexicalizedSense isEvokedBy].each do |k|
            arr = result[k]
            result[k] = arr.uniq if arr.respond_to?(:uniq!)
          end
          result
        end

        # Override getters to ensure values are available for serialization even when not eager-loaded
        def definition
          val = instance_variable_defined?(:@definition) ? instance_variable_get(:@definition) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            begin
              data = computed
              val = data["definition"] if data && data.key?("definition")
              instance_variable_set(:@definition, val) if val
            rescue StandardError
            end
          end
          val
        end

        def inScheme
          val = instance_variable_defined?(:@inScheme) ? instance_variable_get(:@inScheme) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            begin
              data = computed
              val = data["inScheme"] if data && data.key?("inScheme")
              instance_variable_set(:@inScheme, val) if val
            rescue StandardError
            end
          end
          val
        end

        def lexicalizedSense
          val = instance_variable_defined?(:@lexicalizedSense) ? instance_variable_get(:@lexicalizedSense) : nil
          if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            begin
              data = computed
              val = data["lexicalizedSense"] if data && data.key?("lexicalizedSense")
              instance_variable_set(:@lexicalizedSense, val) if val
            rescue StandardError
            end
          end
          val
        end

        def isEvokedBy
          begin
            data = computed
            return (data["isEvokedBy"] || []) if data
          rescue StandardError
          end
          []
        end

        def ensure_computed
          return if defined?(@_computed_populated) && @_computed_populated
          data = computed
          if data && data.is_a?(Hash)
            self.definition = data["definition"] if data.key?("definition")
            self.inScheme = data["inScheme"] if data.key?("inScheme")
            if data.key?("lexicalizedSense")
              # Provide IRIs as strings or map to read_only senses if needed later
              self.lexicalizedSense = Array(data["lexicalizedSense"])
            end
            # isEvokedBy is computed-only (no attribute), expose via computed
          end
          @_computed_populated = true
        end

        def to_hash(options = {})
          begin
            ensure_computed
          rescue StandardError
          end
          h = super(options)
          # Always include subject
          begin
            h["subject"] = self.subject if self.respond_to?(:subject)
          rescue StandardError
            h["subject"] = self.id.to_s if self.id
          end
          
          # Ensure computed fields are included
          begin
            inst = {
              "definition" => (instance_variable_defined?(:@definition) ? @definition : nil),
              "inScheme" => (instance_variable_defined?(:@inScheme) ? @inScheme : nil),
              "lexicalizedSense" => (instance_variable_defined?(:@lexicalizedSense) ? @lexicalizedSense : nil),
            }
            inst.each do |k, v|
              h[k] ||= v unless v.nil?
            end
          rescue StandardError
          end
          
          begin
            comp = self.computed
            if comp && comp.is_a?(Hash)
              %w[definition inScheme lexicalizedSense].each do |k|
                v = comp[k]
                h[k] ||= v unless v.nil? || (v.respond_to?(:empty?) && v.empty?)
              end
              h["isEvokedBy"] ||= comp["isEvokedBy"] if comp.key?("isEvokedBy")
            end
          rescue StandardError
          end
          
          # Normalize empty keys to [] so they serialize as arrays (except subject which can be an object)
          %w[definition inScheme lexicalizedSense isEvokedBy].each do |k|
            h[k] = [] if !h.key?(k) || h[k].nil?
          end
          h
        end

        def self.read_only_enriched(id:, submission:)
          return nil unless id && submission
          rid = nil
          begin
            rid = id.is_a?(RDF::URI) ? id : RDF::URI(id.to_s)
          rescue StandardError
            rid = nil
          end
          return nil unless rid && rid.is_a?(RDF::URI) && rid.to_s.start_with?("http")

          # Build a lightweight instance to compute values
          tmp = self.new
          begin
            tmp.id = rid
            tmp.submission = submission
            tmp.ensure_computed if tmp.respond_to?(:ensure_computed)
          rescue StandardError
          end

          # Return a read_only struct enriched with semantic fields
          attrs = { id: rid, submission: submission, subject: rid.to_s,
                    prefLabel: [], definition: [], inScheme: [], broader: [], narrower: [], lexicalizedSense: [] }
          begin
            pl = tmp.respond_to?(:prefLabel) ? tmp.prefLabel : nil
            d = tmp.respond_to?(:definition) ? tmp.definition : nil
            ins = tmp.respond_to?(:inScheme) ? tmp.inScheme : nil
            br = tmp.respond_to?(:broader) ? tmp.broader : nil
            nr = tmp.respond_to?(:narrower) ? tmp.narrower : nil
            ls = tmp.respond_to?(:lexicalizedSense) ? tmp.lexicalizedSense : nil
            comp = tmp.respond_to?(:computed) ? tmp.computed : nil
            iev = comp && comp.is_a?(Hash) ? comp["isEvokedBy"] : nil
            attrs[:isEvokedBy] = Array(iev).uniq if iev
            # Ensure keys exist with arrays for serialization
            attrs[:prefLabel] = pl if pl && !(pl.respond_to?(:empty?) && pl.empty?)
            attrs[:definition] = d if d && !(d.respond_to?(:empty?) && d.empty?)
            attrs[:inScheme] = ins if ins && !(ins.respond_to?(:empty?) && ins.empty?)
            attrs[:broader] = br if br && !(br.respond_to?(:empty?) && br.empty?)
            attrs[:narrower] = nr if nr && !(nr.respond_to?(:empty?) && nr.empty?)
            attrs[:lexicalizedSense] = if ls && !(ls.respond_to?(:empty?) && ls.empty?)
                Array(ls).map { |x| x.respond_to?(:id) ? x.id.to_s : x.to_s }.uniq
              else
                []
              end
          rescue StandardError
          end
          ro = self.read_only(attrs)
          # Ensure default-serialized methods return our enriched values without hitting SPARQL again
          begin
            ro.define_singleton_method(:subject) { attrs[:subject] }
          rescue StandardError
          end
          begin
            ro.define_singleton_method(:prefLabel) { attrs[:prefLabel] || [] }
          rescue StandardError
          end
          begin
            ro.define_singleton_method(:definition) { attrs[:definition] || [] }
          rescue StandardError
          end
          begin
            ro.define_singleton_method(:inScheme) { attrs[:inScheme] || [] }
          rescue StandardError
          end
          begin
            ro.define_singleton_method(:broader) { attrs[:broader] || [] }
          rescue StandardError
          end
          begin
            ro.define_singleton_method(:narrower) { attrs[:narrower] || [] }
          rescue StandardError
          end
          begin
            ro.define_singleton_method(:lexicalizedSense) { attrs[:lexicalizedSense] || [] }
          rescue StandardError
          end
          begin
            ro.define_singleton_method(:isEvokedBy) { attrs[:isEvokedBy] || [] }
          rescue StandardError
          end
          ro
        end

        def self.list_in_submission(submission, page, size, _include_attrs = [])
          return [] unless submission
          graph = submission.id
          offset = (page - 1) * size
          ontolex_type = "http://www.w3.org/ns/lemon/ontolex#LexicalConcept"
          
          # Only select LexicalConcepts - don't include SKOS Concepts or use inference
          q = [
            "SELECT DISTINCT ?c WHERE {",
            "  GRAPH <#{graph}> {",
            "    ?c a <#{ontolex_type}> .",
            "    FILTER(isIRI(?c))",
            "  }",
            "} ORDER BY ?c LIMIT #{size} OFFSET #{offset}",
          ].join("\n")
          
          epr = Goo.sparql_query_client(:main)
          rows = []
          begin
            rows = epr.query(q, graphs: [graph])
          rescue StandardError
            rows = []
          end
          ids = rows.map { |row| row[:c].to_s }.select { |s| !s.to_s.empty? }
          return [] if ids.empty?
          
          # Build enriched concepts inline
          ids.map do |cid|
            build_concept_attrs(cid, graph, submission, epr)
          end
        end
        
        # Helper method to build concept attributes from SPARQL
        def self.build_concept_attrs(cid, graph, submission, epr)
          def_p = "http://www.w3.org/2004/02/skos/core#definition"
          ins_p = "http://www.w3.org/2004/02/skos/core#inScheme"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          ls_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          ls_inv_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          subj_p = "http://purl.org/dc/terms/subject"
          
          # Query 1: Get basic concept properties
          qry = [
            "SELECT ?p ?o WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { <#{cid}> }",
            "    {",
            "      ?s ?p ?o .",
            "      FILTER(?p IN (<#{def_p}>, <#{ins_p}>, <#{ls_p}>, <#{subj_p}>))",
            "    } UNION {",
            "      ?ls <#{ls_inv_p}> ?s .",
            "      BIND(<#{ls_p}> AS ?p) BIND(?ls AS ?o)",
            "    } UNION {",
            "      ?e <#{evokes_p}> ?s .",
            "      BIND(<http://www.w3.org/ns/lemon/ontolex#isEvokedBy> AS ?p) BIND(?e AS ?o)",
            "    }",
            "  }",
            "}",
          ].join("\n")
          
          attrs = { id: RDF::URI(cid), submission: submission }
          subj_uri = nil
          def_uris = []
          
          begin
            epr.query(qry, graphs: [graph]).each do |row|
              case row[:p].to_s
              when def_p
                def_uris << row[:o].to_s
              when ins_p
                (attrs[:inScheme] ||= []) << row[:o].to_s
              when ls_p
                (attrs[:lexicalizedSense] ||= []) << row[:o].to_s
              when subj_p
                subj_uri = row[:o].to_s
              when "http://www.w3.org/ns/lemon/ontolex#isEvokedBy"
                (attrs[:isEvokedBy] ||= []) << row[:o].to_s
              end
            end
          rescue StandardError
          end
          
          # Query 2: Batch resolve all definitions if any
          if !def_uris.empty?
            def_uris = def_uris.uniq  # Dedup before batching
            lang_p = "http://purl.org/dc/terms/language"
            rdfs_label = "http://www.w3.org/2000/01/rdf-schema#label"
            def_values = def_uris.map { |u| "<#{u}>" }.join(" ")
            
            def_q = [
              "SELECT ?d ?lang ?label WHERE {",
              "  GRAPH <#{graph}> {",
              "    VALUES ?d { #{def_values} }",
              "    ?d <#{lang_p}> ?lang .",
              "    OPTIONAL { ?d <#{rdfs_label}> ?label }",
              "  }",
              "}",
            ].join("\n")
            
            def_map = {}
            begin
              epr.query(def_q, graphs: [graph]).each do |row|
                uri = row[:d].to_s
                def_map[uri] = {
                  "id" => uri,
                  "language" => row[:lang] ? row[:lang].to_s : nil,
                  "label" => row[:label] ? row[:label].to_s : nil
                }
              end
            rescue StandardError
            end
            
            # Include all definitions, even if not resolved
            attrs[:definition] = def_uris.map { |u| def_map[u] || { "id" => u } }
          end
          
          # Query 3: Resolve subject SKOS properties if present
          if subj_uri && !subj_uri.empty?
            bro_p = "http://www.w3.org/2004/02/skos/core#broader"
            nar_p = "http://www.w3.org/2004/02/skos/core#narrower"
            pref_p = "http://www.w3.org/2004/02/skos/core#prefLabel"
            top_p = "http://www.w3.org/2004/02/skos/core#topConceptOf"
            
            subj_q = [
              "SELECT ?p ?o WHERE {",
              "  GRAPH <#{graph}> {",
              "    <#{subj_uri}> ?p ?o .",
              "    FILTER(?p IN (<#{bro_p}>, <#{nar_p}>, <#{pref_p}>, <#{top_p}>))",
              "  }",
              "}",
            ].join("\n")
            
            subj_attrs = { "@id" => subj_uri }
            begin
              epr.query(subj_q, graphs: [graph]).each do |row|
                case row[:p].to_s
                when bro_p
                  (subj_attrs["broader"] ||= []) << row[:o].to_s
                when nar_p
                  (subj_attrs["narrower"] ||= []) << row[:o].to_s
                when pref_p
                  (subj_attrs["prefLabel"] ||= []) << row[:o].to_s
                when top_p
                  (subj_attrs["isTopConceptOf"] ||= []) << row[:o].to_s
                end
              end
              
              # Dedup subject arrays
              %w[broader narrower prefLabel isTopConceptOf].each do |k|
                arr = subj_attrs[k]
                subj_attrs[k] = arr.uniq if arr && arr.respond_to?(:uniq)
              end
            rescue StandardError
            end
            
            attrs[:subject] = subj_attrs
          else
            attrs[:subject] = cid
          end
          
          # Dedup main arrays
          [:inScheme, :lexicalizedSense, :isEvokedBy].each do |k|
            arr = attrs[k]
            attrs[k] = arr.uniq if arr.respond_to?(:uniq)
          end
          
          LinkedData::Models::OntoLex::LexicalConcept.read_only(attrs)
        end

        # Build enriched read_only concepts for specific IRIs (parity with list endpoint)
        def self.list_for_ids(submission, ids, _include_attrs = [])
          return [] unless submission && ids && !ids.empty?
          graph = submission.id
          epr = Goo.sparql_query_client(:main)
          
          ids.map do |iri|
            cid = iri.to_s
            next nil if cid.empty?
            build_concept_attrs(cid, graph, submission, epr)
          end.compact
        end

        def self.count_in_submission(submission)
          return 0 unless submission
          graph = submission.id
          ontolex_type = "http://www.w3.org/ns/lemon/ontolex#LexicalConcept"
          skos_type_http = "http://www.w3.org/2004/02/skos/core#Concept"
          skos_type_https = "https://www.w3.org/2004/02/skos/core#Concept"
          lc_inv_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          skos_pref_http = "http://www.w3.org/2004/02/skos/core#prefLabel"
          skos_pref_https = "https://www.w3.org/2004/02/skos/core#prefLabel"
          rdfs_label = "http://www.w3.org/2000/01/rdf-schema#label"
          dct_title = "http://purl.org/dc/terms/title"
          epr = Goo.sparql_query_client(:main)
          begin
            q = [
              "SELECT (COUNT(DISTINCT ?c) AS ?count) WHERE {",
              "  GRAPH <#{graph}> {",
              "    { ?c a <#{ontolex_type}> }",
              "    UNION { ?c a <#{skos_type_http}> }",
              "    UNION { ?c a <#{skos_type_https}> }",
              "    UNION { ?s <#{lc_inv_p}> ?c }",
              "    UNION { ?e <#{evokes_p}> ?c }",
              "    UNION { ?c <#{skos_pref_http}> ?l }",
              "    UNION { ?c <#{skos_pref_https}> ?l }",
              "    UNION { ?c <#{rdfs_label}> ?l }",
              "    UNION { ?c <#{dct_title}> ?l }",
              "    FILTER(isIRI(?c))",
              "  }",
              "}",
            ].join("\n")
            row = epr.query(q, graphs: [graph]).first
            (row && row[:count]) ? row[:count].to_s.to_i : 0
          rescue StandardError
            0
          end
        end

        def self.list_ids_basic(submission, page, size)
          return [] unless submission
          graph = submission.id
          offset = (page - 1) * size
          ontolex_type = "http://www.w3.org/ns/lemon/ontolex#LexicalConcept"
          skos_type_http = "http://www.w3.org/2004/02/skos/core#Concept"
          skos_type_https = "https://www.w3.org/2004/02/skos/core#Concept"
          lc_inv_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          skos_pref_http = "http://www.w3.org/2004/02/skos/core#prefLabel"
          skos_pref_https = "https://www.w3.org/2004/02/skos/core#prefLabel"
          rdfs_label = "http://www.w3.org/2000/01/rdf-schema#label"
          dct_title = "http://purl.org/dc/terms/title"
          q = [
            "SELECT DISTINCT ?c WHERE {",
            "  GRAPH <#{graph}> {",
            "    { ?c a <#{ontolex_type}> }",
            "    UNION { ?c a <#{skos_type_http}> }",
            "    UNION { ?c a <#{skos_type_https}> }",
            "    UNION { ?s <#{lc_inv_p}> ?c }",
            "    UNION { ?e <#{evokes_p}> ?c }",
            "    UNION { ?c <#{skos_pref_http}> ?l }",
            "    UNION { ?c <#{skos_pref_https}> ?l }",
            "    UNION { ?c <#{rdfs_label}> ?l }",
            "    UNION { ?c <#{dct_title}> ?l }",
            "    FILTER(isIRI(?c))",
            "  }",
            "} ORDER BY ?c LIMIT #{size} OFFSET #{offset}",
          ].join("\n")
          epr = Goo.sparql_query_client(:main)
          rows = []
          begin
            rows = epr.query(q, graphs: [graph])
          rescue StandardError
            rows = []
          end
          rows.map { |r| r[:c].to_s }.select { |s| !s.empty? }
        end
      end
    end
  end
end
