module LinkedData
  module Models
    module OntoLex
      class LexicalSense < LinkedData::Models::Base
    model :lexical_sense, name_with: :id, collection: :submission,
      namespace: :ontolex, schemaless: :true,
              rdf_type: ->(*_x) { RDF::URI('http://www.w3.org/ns/lemon/ontolex#LexicalSense') }

  attribute :definition, namespace: :dcterms
  attribute :example, namespace: :dcterms, property: :example
        attribute :reference, namespace: :ontolex
  attribute :isSenseOf, namespace: :ontolex, range: -> { LinkedData::Models::OntoLex::LexicalEntry }
  attribute :lexicalConcept, namespace: :ontolex, property: :isLexicalizedSenseOf, range: -> { LinkedData::Models::OntoLex::LexicalConcept }
  attribute :translation, namespace: :vartrans
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

  serialize_default :definition, :example, :reference, :lexicalConcept
        serialize_never :submission
  serialize_methods :properties
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new('self', ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_senses/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new('ontology', ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary['Ontology'])

        def properties
          self.unmapped
        end
      end
    end
  end
end
