require 'csv'

module LinkedData
  module Metrics
    def self.metrics_for_submission(submission, logger)
      metrics = nil
      logger.info('metrics_for_submission start')
      logger.flush
      begin
        submission.bring(:submissionStatus) if submission.bring?(:submissionStatus)
        cls_metrics = class_metrics(submission, logger)
        logger.info('class_metrics finished')
        logger.flush
        metrics = LinkedData::Models::Metric.new

        cls_metrics.each do |k, v|
          unless v.instance_of?(Integer)
            begin
              v = Integer(v)
            rescue ArgumentError
              v = 0
            rescue TypeError
              v = 0
            end
          end
          metrics.send("#{k}=", v)
        end
        indiv_count = number_individuals(logger, submission)
        metrics.individuals = indiv_count
        logger.info('individuals finished')
        logger.flush
        prop_count = number_properties(logger, submission)
        metrics.properties = prop_count
        logger.info('properties finished')
        logger.flush

        # OntoLex counts
        begin
          o_entries = LinkedData::Models::OntoLex::LexicalEntry.count_in_submission(submission)
          o_forms   = LinkedData::Models::OntoLex::Form.count_in_submission(submission)
          o_senses  = LinkedData::Models::OntoLex::LexicalSense.count_in_submission(submission)
          o_concepts = LinkedData::Models::OntoLex::LexicalConcept.count_in_submission(submission)
          metrics.ontolexEntries = o_entries
          metrics.ontolexForms   = o_forms
          metrics.ontolexSenses  = o_senses
          metrics.ontolexConcepts = o_concepts
          logger.info('ontolex metrics finished')
          logger.flush
        rescue Exception => e
          logger.error("Error computing OntoLex metrics: #{e}")
          logger.flush
          o_entries = 0
          o_forms = 0
          o_senses = 0
          o_concepts = 0
        end

        # re-generate metrics file
        submission.generate_metrics_file(cls_metrics[:classes], indiv_count, prop_count, cls_metrics[:maxDepth],
                                         o_entries, o_forms, o_senses, o_concepts)
        logger.info('generation of metrics file finished')
        logger.flush
      rescue Exception => e
        logger.error(e.message)
        logger.error(e)
        logger.flush
        metrics = nil
      end
      metrics
    end

    def self.max_depth_fn(submission, logger, is_flat, rdfsSC)
      max_depth = 0
      mx_from_file = submission.metrics_from_file(logger)
      if mx_from_file && mx_from_file.length == 2 && mx_from_file[0].length >= 4
        max_depth = mx_from_file[1][3].to_i
        logger.info("Metrics max_depth retrieved #{max_depth} from the metrics csv file.")
      else
        logger.info("Unable to find metrics providing max_depth in file for submission #{submission.id}.  Using ruby calculation of max_depth.")
        roots = submission.roots

        unless is_flat
          depths = []
          roots.each do |root|
            ok = true
            n = 1
            while ok
              ok = hierarchy_depth?(submission.id.to_s, root.id.to_s, n, rdfsSC)
              n += 1 if ok
              if n > 40
                # safe guard
                ok = false
              end
            end
            n -= 1
            depths << n
          end
          max_depth = depths.max
        end
      end
      max_depth
    end

    def self.class_metrics(submission, logger)
      t00 = Time.now
      submission.ontology.bring(:flat) if submission.ontology.bring?(:flat)

      is_flat = submission.ontology.flat
      rdfsSC = nil
      rdfsSC = Goo.namespaces[:rdfs][:subClassOf] unless is_flat
      max_depth = max_depth_fn(submission, logger, is_flat, rdfsSC)

      cls_metrics = {}
      cls_metrics[:classes] = 0
      cls_metrics[:averageChildCount] = 0
      cls_metrics[:maxChildCount] = 0
      cls_metrics[:classesWithOneChild] = 0
      cls_metrics[:classesWithMoreThan25Children] = 0
      cls_metrics[:classesWithNoDefinition] = 0
      cls_metrics[:maxDepth] = max_depth
      definitionP = [Goo.namespaces[:skos][:definition],
                     LinkedData::Utils::Triples.obo_definition_standard,
                     Goo.namespaces[:rdfs][:comment]]
      submission.bring(:definitionProperty)
      definitionP << submission.definitionProperty unless submission.definitionProperty.nil?
      t0 = Time.now
      groupby_children = query_groupby_classes(submission.id, rdfsSC)
      logger.info("Metrics groupby_children retrieved #{groupby_children.length}" +
                  " in #{Time.now - t0} sec.")
      logger.flush
      children_counts = []
      groupby_children.each do |cls, count|
        next unless cls.start_with?('http')

        next if is_flat

        cls_metrics[:classesWithMoreThan25Children] += 1 if count > 24
        cls_metrics[:classesWithOneChild] += 1 if count == 1
        children_counts << count if count > 0
        cls_metrics[:maxChildCount] = count if count > cls_metrics[:maxChildCount]
      end
      t0 = Time.now
      count_classes = number_classes(logger, submission)
      cls_metrics[:classes] = count_classes
      logger.info("Metrics count_classes retrieved #{count_classes}" +
                  " in #{Time.now - t0} sec.")
      logger.flush
      t0 = Time.now
      withDef = query_count_definitions(submission.id, definitionP)
      logger.info("Metrics count cls with def #{withDef}" +
                  " in #{Time.now - t0} sec.")
      logger.flush
      cls_metrics[:classesWithNoDefinition] = cls_metrics[:classes] - withDef
      sum = 0
      children_counts.each do |c|
        sum += c
      end
      cls_metrics[:averageChildCount] = (sum.to_f / children_counts.length.to_f).to_i if children_counts.length > 0
      logger.info("Class metrics finished in #{Time.now - t00} sec.")
      logger.flush
      cls_metrics
    end

    def self.recursive_depth(cls, classes, depth, visited)
      if depth > 60
        # safety for cycles.
        return depth
      end

      children = classes[cls]
      branch_depts = [depth + 1]
      children.each do |ch|
        if classes[ch] && !visited.include?(ch)
          visited << ch
          branch_depts << recursive_depth(ch, classes, depth + 1, visited)
        end
      end
      branch_depts.max
    end

    def self.number_classes(logger, submission)
      class_count = 0
      m_from_file = submission.metrics_from_file(logger)

      if m_from_file && m_from_file.length == 2
        class_count = m_from_file[1][0].to_i
      else
        logger.info("Unable to find metrics in file for submission #{submission.id}. Performing a COUNT query to get the total class count...")
        logger.flush
        class_count = query_count_classes(submission.id)
      end
      class_count
    end

    def self.number_individuals(logger, submission)
      indiv_count = 0
      m_from_file = submission.metrics_from_file(logger)

      if m_from_file && m_from_file.length == 2
        indiv_count = m_from_file[1][1].to_i
      else
        logger.info("Unable to find metrics in file for submission #{submission.id}. Performing a COUNT of type query to get the total individual count...")
        logger.flush
        indiv_count = count_owl_type(submission.id, 'NamedIndividual')
      end
      indiv_count
    end

    def self.number_properties(logger, submission)
      prop_count = 0
      m_from_file = submission.metrics_from_file(logger)

      if m_from_file && m_from_file.length == 2
        prop_count = m_from_file[1][2].to_i
      else
        logger.info("Unable to find metrics in file for submission #{submission.id}. Performing a COUNT of type query to get the total property count...")
        logger.flush
        prop_count = count_owl_type(submission.id, 'DatatypeProperty')
        prop_count += count_owl_type(submission.id, 'ObjectProperty')
      end
      prop_count
    end

    def self.hierarchy_depth?(graph, root, n, treeProp)
      sTemplate = "children <#{treeProp}> parent"
      hops = []
      vars = []
      n.times do |i|
        hop = sTemplate.sub('children', "?x#{i}")
        hop = if i == 0
                hop.sub('parent', "<#{root}>")
              else
                hop.sub('parent', "?x#{i - 1}")
              end
        hops << hop
        vars << "?x#{i}"
      end
      joins = hops.join(".\n")
      vars = vars.join(' ')
      query = <<~EOF
        SELECT #{vars} WHERE {
          GRAPH <#{graph}> {
            #{joins}
          } } LIMIT 1
      EOF
      rs = Goo.sparql_query_client.query(query)
      items = Set.new
      rs.each do |sol|
        n.times do |i|
          item = sol["x#{i}"]
          if items.include?(item)
            # there is a cycle
            return false
          end

          items << item
        end
        return true
      end
      false
    end

    def self.query_count_definitions(subId, defProps)
      propFilter = defProps.map { |x| "?p = <#{x}>" }
      propFilter = propFilter.join ' || '
      query = <<~EOS
        SELECT (count(DISTINCT ?s) as ?c) WHERE {
            GRAPH <#{subId}> {
                  ?s a <#{Goo.namespaces[:owl][:Class]}> .
                    ?s ?p ?o .
                  FILTER ( properties )
                  FILTER ( !isBlank(?s) )
                  FILTER (?s != <#{Goo.namespaces[:owl][:Thing]}>)
        }}
      EOS
      query = query.sub('properties', propFilter)
      rs = Goo.sparql_query_client.query(query)
      rs.each do |sol|
        return sol[:c].object
      end
      0
    end

    def self.query_groupby_classes(subId, treeProp)
      query = <<~EOS
        SELECT ?o (count(?s) as ?c) WHERE {#{' '}
            GRAPH <#{subId}> {
                  ?s <#{treeProp}> ?o .
            FILTER (?s != <#{Goo.namespaces[:owl][:Thing]}>)
            }}
        GROUP BY ?o
      EOS
      rs = Goo.sparql_query_client.query(query)
      groupby_counts = {}
      rs.each do |sol|
        groupby_counts[sol[:o].to_s] = sol[:c].object
      end
      groupby_counts
    end

    def self.query_count_classes(subId)
      query = <<~EOS
        SELECT (count(?s) as ?c) WHERE {
            GRAPH <#{subId}> {
              ?s a <#{Goo.namespaces[:owl][:Class]}> .
              FILTER(!isBlank(?s))
              FILTER (?s != <#{Goo.namespaces[:owl][:Thing]}>)
            }
        }
      EOS
      rs = Goo.sparql_query_client.query(query)
      rs.each do |sol|
        return sol[:c].object
      end
      0
    end

    def self.count_owl_type(graph, name)
      owl_type = Goo.namespaces[:owl][name]
      query = <<~EOF
        SELECT (COUNT(?s) as ?count) WHERE {
          GRAPH #{graph.to_ntriples} {
            ?s a #{owl_type.to_ntriples}
            FILTER (?s != <#{Goo.namespaces[:owl][:Thing]}>)
          } }
      EOF
      rs = Goo.sparql_query_client.query(query)
      rs.each do |sol|
        return sol[:count].object
      end
      0
    end
  end
end
