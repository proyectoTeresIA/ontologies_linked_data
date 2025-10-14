module LinkedData
  module Models
    module OntoLex
      class LexicalEntry < LinkedData::Models::Base
        model :lexical_entry, name_with: :id, collection: :submission,
          namespace: :ontolex, schemaless: :true,
              rdf_type: ->(*_x) { RDF::URI('http://www.w3.org/ns/lemon/ontolex#LexicalEntry') }

        attribute :lemma, namespace: :ontolex
        attribute :language, namespace: :dcterms
        attribute :partOfSpeech, namespace: :lexinfo
        attribute :entryType, namespace: :ontolex
        attribute :form, namespace: :ontolex, range: -> { LinkedData::Models::OntoLex::Form }
        attribute :sense, namespace: :ontolex, range: -> { LinkedData::Models::OntoLex::LexicalSense }
        attribute :concept, namespace: :ontolex, property: :evokes, range: -> { LinkedData::Models::OntoLex::LexicalConcept }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        # Hypermedia
        embed :form, :sense
        serialize_default :lemma, :language, :partOfSpeech, :entryType, :form, :sense
        serialize_never :submission
        serialize_methods :properties
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new('self', ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_entries/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new('ontology', ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary['Ontology'])

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
        def index_doc(to_set=nil)
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

          [:lemma, :language, :partOfSpeech, :entryType].each do |att|
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
        def self.search(q, params={})
          super(q, params, :lexical)
        end
      end
    end
  end
end
