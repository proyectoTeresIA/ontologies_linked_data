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
      end
    end
  end
end
