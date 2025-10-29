module LinkedData
  module Models
    module OntoLex
      class LexicalEntry < LinkedData::Models::Base
        model :lexical_entry, name_with: :id, collection: :submission,
                              namespace: :ontolex, schemaless: :true,
                              rdf_type: ->(*_x) { RDF::URI("http://www.w3.org/ns/lemon/ontolex#LexicalEntry") }

        attribute :lemma, namespace: :ontolex
        attribute :language, namespace: :dcterms
        attribute :partOfSpeech, namespace: :lexinfo
        attribute :termType, namespace: :lexinfo, property: :termType
        # Use the actual predicate from the TTL files
        attribute :form, namespace: :ontolex, enforce: [:list], property: :lexicalForm
        attribute :canonicalForm, namespace: :ontolex
        attribute :otherForm, namespace: :ontolex, enforce: [:list]
        attribute :sense, namespace: :ontolex, enforce: [:list]
        attribute :evokes, namespace: :ontolex, property: :evokes
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        # Hypermedia / serialization
        serialize_default :lemma, :language, :partOfSpeech, :termType, :form, :sense, :evokes
        serialize_never :submission
        serialize_methods :properties
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new("self", ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_entries/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new("ontology", ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary["Ontology"])

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def properties
          self.unmapped
        end

        # Build a stable per-submission Solr id similar to Class/Property
        def index_id
          self.bring(:submission) if self.bring?(:submission)
          return nil unless self.submission
          self.submission.bring(:submissionId) if self.submission.bring?(:submissionId)
          self.submission.bring(:ontology) if self.submission.bring?(:ontology)
          return nil unless self.submission.ontology
          self.submission.ontology.bring(:acronym) if self.submission.ontology.bring?(:acronym)
          "#{self.id.to_s}_#{self.submission.ontology.acronym}_#{self.submission.submissionId}"
        end

        # Compute Solr document for lexical entries
        def index_doc(to_set = nil)
          doc = {}
          # Required fields: stable unique id for this submission and original resource IRI
          # Use a stable per-submission unique id for the Solr document, similar to classes/properties
          doc[:id] = self.index_id || self.id.to_s
          doc[:resource_id] = self.id.to_s
          self.bring(:submission) if self.bring?(:submission)
          return doc unless self.submission

          # Submission/ontology fields
          doc[:ontologyId] = self.submission.id.to_s
          doc[:submissionAcronym] = self.submission.ontology.acronym
          doc[:submissionId] = self.submission.submissionId

          # Core lexical fields (lemma/writtenRep/language/pos/type)
          all_attrs = self.to_hash(include_languages: true)

          [:lemma, :language, :partOfSpeech, :termType].each do |att|
            val = all_attrs[att]
            next if val.nil? || (val.respond_to?(:empty?) && val.empty?)
            if val.is_a?(Hash)
              # language-tagged hash → index all variants and per-language dynamic
              doc[att] = val.values.flatten
              val.each { |lang, values| doc["#{att}_#{lang}".to_sym] = values }
            else
              doc[att] = Array(val).map(&:to_s)
            end
          end

          # Forms: flatten writtenRep from embedded forms if present
          if self.form
            reps = []
            Array(self.form).each do |f|
              if f.respond_to?(:writtenRep) && f.writtenRep
                reps.concat(Array(f.writtenRep))
              end
            end
            reps.uniq!
            doc[:writtenRep] = reps unless reps.empty?
          end

          # Senses: definitions/examples and concept labels
          if self.sense
            defs = []
            exs = []
            concepts = []
            concept_labels = []
            Array(self.sense).each do |s|
              defs.concat(Array(s.definition)) if s.respond_to?(:definition) && s.definition
              exs.concat(Array(s.example)) if s.respond_to?(:example) && s.example
              if s.respond_to?(:lexicalConcept) && s.lexicalConcept
                Array(s.lexicalConcept).each do |lc|
                  concepts << lc.id.to_s
                  if lc.respond_to?(:prefLabel) && lc.prefLabel
                    concept_labels.concat(Array(lc.prefLabel))
                  end
                end
              end
            end
            doc[:definition] = defs unless defs.empty?
            doc[:example] = exs unless exs.empty?
            doc[:concept] = concepts.uniq unless concepts.empty?
            doc[:conceptLabel] = concept_labels.uniq unless concept_labels.empty?
          end

          # Concepts directly evoked by the entry (ensure they are indexed even without senses)
          begin
            evoked_ids = self.respond_to?(:evokes_ids) ? Array(self.evokes_ids) : []
            unless evoked_ids.empty?
              doc[:concept] = (Array(doc[:concept]) + evoked_ids).uniq
            end
          rescue StandardError
          end

          # Raw properties if needed
          props = properties_for_indexing
          if props
            doc[:property] = props[:property]
            doc[:propertyRaw] = props[:propertyRaw]
          end

          doc
        end

        def properties_for_indexing
          self_props = self.properties
          return nil if self_props.nil?

          props = {}
          prop_vals = []
          self_props.each do |attr_key, attr_val|
            if attr_val.is_a?(Array)
              props[attr_key] = []
              attr_val.uniq.each do |val|
                real = val.kind_of?(Goo::Base::Resource) ? val.id.to_s : val.to_s.strip
                next if real.respond_to?(:empty?) && real.empty?
                prop_vals << real
                props[attr_key] << real
              end
            else
              real = attr_val.to_s.strip
              next if real.respond_to?(:empty?) && real.empty?
              prop_vals << real
              props[attr_key] = real
            end
          end

          begin
            { propertyRaw: MultiJson.dump(props), property: prop_vals.uniq }
          rescue JSON::GeneratorError
            nil
          end
        end

        # Route searches to the lexical backend (Solr core)
        def self.search(q, params = {})
          super(q, params, :lexical)
        end

        # Standard serialization - Goo handles everything now
        def to_hash(options = {})
          super(options)
        end

        # Class-level helpers
        def self.count_in_submission(submission)
          return 0 unless submission
          # Custom count needed to support both ontolex: and lemon: namespaces
          graph = submission.id
          ontolex = "http://www.w3.org/ns/lemon/ontolex#"
          lemon = "http://lemon-model.net/lemon#"
          epr = Goo.sparql_query_client(:main)
          begin
            q = [
              "SELECT (COUNT(DISTINCT ?s) AS ?count) WHERE {",
              "  GRAPH <#{graph}> {",
              "    { ?s a <#{ontolex}LexicalEntry> } UNION { ?s a <#{lemon}LexicalEntry> }",
              "  }",
              "}",
            ].join("\n")
            row = epr.query(q, graphs: [graph]).first
            (row && row[:count]) ? row[:count].to_s.to_i : 0
          rescue StandardError
            0
          end
        end

        def self.list_in_submission(submission, page, size, include_attrs = [])
          return [] unless submission
          include_attrs = [:lemma, :language, :partOfSpeech, :form, :sense, :evokes] if include_attrs.empty?
          LexicalEntry.in(submission).include(*include_attrs).page(page, size).all
        end

        # Build enriched read_only entries for specific IRIs (parity with list endpoint)
        def self.list_for_ids(submission, ids, include_attrs = [])
          return [] unless submission && ids && !ids.empty?
          
          include_attrs = [:lemma, :language, :partOfSpeech, :form, :sense, :evokes] if include_attrs.empty?
          
          # Convert IDs to RDF::URI if needed, ensuring valid URIs
          entry_ids = ids.map do |id|
            next id if id.is_a?(RDF::URI)
            begin
              uri_str = id.to_s.strip
              # Ensure the URI is valid
              next nil if uri_str.empty?
              RDF::URI.new(uri_str)
            rescue => e
              puts "[LexicalEntry] Failed to create RDF::URI from: #{id.inspect} - #{e.message}"
              nil
            end
          end.compact
          
          return [] if entry_ids.empty?
          
          # Query each ID individually and collect results
          entry_ids.map do |uri|
            LexicalEntry.find(uri).in(submission).include(*include_attrs).first
          end.compact
        end
      end
    end
  end
end
