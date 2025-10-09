module LinkedData
  module Models
    module OntoLex
      class Form < LinkedData::Models::Base
        model :form, name_with: :id, collection: :submission,
          namespace: :ontolex, schemaless: :true,
              rdf_type: ->(*_x) { RDF::URI('http://www.w3.org/ns/lemon/ontolex#Form') }

        attribute :writtenRep, namespace: :ontolex
        attribute :language, namespace: :dcterms
        attribute :formType, namespace: :ontolex
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        serialize_default :writtenRep, :language, :formType
        serialize_never :submission
        serialize_methods :properties

        link_to LinkedData::Hypermedia::Link.new('self', ->(s) { "ontologies/#{s.submission.ontology.acronym}/forms/#{CGI.escape(s.id.to_s)}" }, self.uri_type)

        def properties
          self.unmapped
        end
      end
    end
  end
end
