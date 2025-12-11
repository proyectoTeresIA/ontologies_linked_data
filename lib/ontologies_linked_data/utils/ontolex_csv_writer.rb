require 'csv'
require 'zlib'

module LinkedData
  module Utils
    class OntoLexCSVWriter
      # Column headers for OntoLex LexicalEntry CSV export
      ENTRY_ID = 'Entry ID'
      LEMMA = 'Lemma'
      LANGUAGE = 'Language'
      PART_OF_SPEECH = 'Part of Speech'
      WRITTEN_REP = 'Written Representation'
      SENSE_DEFINITION = 'Sense Definition'
      SENSE_REFERENCE = 'Sense Reference'
      SENSE_EXAMPLE = 'Sense Example'
      FORM_COUNT = 'Form Count'

      def open(path)
        @file = File.new(path, 'w')
        @gz = Zlib::GzipWriter.new(@file)
        @csv = CSV.new(@gz, headers: true, return_headers: true, write_headers: true)
        write_header
      end

      def write_header
        @headers = [ENTRY_ID, LEMMA, LANGUAGE, PART_OF_SPEECH, WRITTEN_REP, 
                    SENSE_DEFINITION, SENSE_REFERENCE, SENSE_EXAMPLE, FORM_COUNT]
        @csv << @headers
      end

      def write_entry(entry)
        row = CSV::Row.new(@headers, Array.new(@headers.size), false)

        # Entry ID
        row[ENTRY_ID] = entry.id.to_s

        # Lemma (canonical form)
        row[LEMMA] = entry.lemma.to_s if entry.lemma

        # Language
        row[LANGUAGE] = entry.language.to_s if entry.language

        # Part of Speech
        row[PART_OF_SPEECH] = entry.partOfSpeech.to_s if entry.partOfSpeech

        # Get written representations from forms data (queried via SPARQL)
        written_reps = []
        forms_data = entry.instance_variable_get(:@forms_data) || []
        forms_data.each do |form_data|
          written_reps << form_data[:writtenRep] if form_data[:writtenRep]
        end
        row[WRITTEN_REP] = written_reps.join(' | ') unless written_reps.empty?
        row[FORM_COUNT] = forms_data.size.to_s

        # Get sense information from senses data (queried via SPARQL)
        definitions = []
        references = []
        examples = []
        senses_data = entry.instance_variable_get(:@senses_data) || []
        senses_data.each do |sense_data|
          definitions << sense_data[:definition] if sense_data[:definition] && !sense_data[:definition].empty?
          references << sense_data[:reference] if sense_data[:reference] && !sense_data[:reference].empty?
          examples << sense_data[:example] if sense_data[:example] && !sense_data[:example].empty?
        end
        row[SENSE_DEFINITION] = definitions.join(' | ') unless definitions.empty?
        row[SENSE_REFERENCE] = references.join(' | ') unless references.empty?
        row[SENSE_EXAMPLE] = examples.join(' | ') unless examples.empty?

        @csv << row
      end

      def close
        @gz.close
        @file.close
        @csv.close
      end
    end
  end
end
