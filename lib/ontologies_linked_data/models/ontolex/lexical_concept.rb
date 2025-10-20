module LinkedData
  module Models
    module OntoLex
      class LexicalConcept < LinkedData::Models::Base
        model :lexical_concept, name_with: :id, collection: :submission,
          namespace: :ontolex, schemaless: :true,
              rdf_type: ->(*_x) { RDF::URI('http://www.w3.org/ns/lemon/ontolex#LexicalConcept') }

        attribute :prefLabel, namespace: :skos
        attribute :definition, namespace: :skos, enforce: [:list]
        attribute :broader, namespace: :skos
        attribute :narrower, namespace: :skos
        attribute :lexicalizedSense, namespace: :ontolex, property: :lexicalizedSense, range: -> { LinkedData::Models::OntoLex::LexicalSense }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        do_not_load :lexicalizedSense
        serialize_default :prefLabel, :definition, :broader, :narrower, :lexicalizedSense
        serialize_never :submission
        serialize_methods :properties
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new('self', ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_concepts/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new('ontology', ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary['Ontology'])

        def properties
          self.unmapped
        end
      end
    end
  end
end
