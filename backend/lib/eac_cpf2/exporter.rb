# frozen_string_literal: true

module EacCpf2
  # Loads an agent and the records it is linked to from the ArchivesSpace
  # database, applies EacCpf2::Publication, and serializes the result.
  #
  # Runs inside the ArchivesSpace backend; everything ArchivesSpace-specific
  # lives here so the serializer and publication rules stay testable on their
  # own.
  class Exporter
    AGENT_MODELS = {
      'people' => 'AgentPerson',
      'corporate_entities' => 'AgentCorporateEntity',
      'families' => 'AgentFamily'
    }.freeze

    RECORD_MODELS = %w[Resource ArchivalObject DigitalObject DigitalObjectComponent].freeze
    RECORD_ORDER = %w[resource archival_object digital_object digital_object_component].freeze

    def self.agent_types
      AGENT_MODELS.keys
    end

    # @return [String] EAC-CPF 2.0 XML
    # @raise [NotFoundException] when the agent does not exist or is unpublished
    def self.export(agent_type, id)
      new(agent_type, id).to_xml
    end

    def initialize(agent_type, id)
      @model = Kernel.const_get(AGENT_MODELS.fetch(agent_type))
      @id = id
    end

    def to_xml
      agent = @model.get_or_die(@id)
      json = @model.to_jsonmodel(agent).to_hash(:trusted)
      raise NotFoundException, 'Agent not found' unless Publication.published?(json)

      json = URIResolver.resolve_references(json, %w[subjects places])
      json['related_agents'] = resolve_related_agents(Array(json['related_agents']))

      Serializer.new(
        agent: Publication.filter_agent(json),
        records: linked_records(agent),
        agency_name: config(:eac_cpf_2_agency_name) || 'ArchivesSpace',
        agency_code: config(:eac_cpf_2_agency_code),
        base_url: config(:eac_cpf_2_base_url) || config(:public_proxy_url),
        label: method(:label)
      ).to_xml
    end

    private

    NAME_MODELS = {
      'agent_person' => ['AgentPerson', 'NamePerson', :agent_person_id],
      'agent_corporate_entity' => ['AgentCorporateEntity', 'NameCorporateEntity', :agent_corporate_entity_id],
      'agent_family' => ['AgentFamily', 'NameFamily', :agent_family_id]
    }.freeze

    # Adds the little the serializer needs about each related agent (type,
    # publish flag, display name) as '_resolved'. URIResolver would load every
    # related agent in full, which takes seconds for a body like a university
    # with hundreds of relationships.
    def resolve_related_agents(relations)
      refs = relations.map { |rel| JSONModel.parse_reference(rel['ref']) }
      resolved = {}

      refs.compact.group_by { |ref| ref[:type] }.each do |type, group|
        agent_model, name_model, column = NAME_MODELS[type]
        next unless agent_model

        ids = group.map { |ref| ref[:id].to_i }.uniq
        published = Kernel.const_get(agent_model).filter(id: ids).select_hash(:id, :publish)
        names = Kernel.const_get(name_model).filter(column => ids, is_display_name: 1).select_hash(column, :sort_name)
        ids.each do |id|
          resolved[[type, id]] = {
            'uri' => JSONModel(type.to_sym).uri_for(id), 'jsonmodel_type' => type,
            'publish' => published[id] == 1, 'display_name' => { 'sort_name' => names[id] }
          }
        end
      end

      relations.zip(refs).map do |rel, ref|
        target = ref && resolved[[ref[:type], ref[:id].to_i]]
        target ? rel.merge('_resolved' => target) : rel
      end
    end

    # Published records linked to the agent, built from database columns
    # rather than full JSON so that agents linked to thousands of records stay
    # fast.
    def linked_records(agent)
      relationship = @model.find_relationship(:linked_agents)
      relations = relationship.find_by_participant(agent)
      enum_ids = relations.flat_map { |rel| [rel[:role_id], rel[:relator_id]] }.compact.uniq
      enums = enum_ids.empty? ? {} : BackendEnumSource.values_for_ids(enum_ids)

      records = relations.filter_map do |relation|
        record = relation.other_referent_than(agent)
        next unless record && RECORD_MODELS.include?(record.class.name)
        next unless record_published?(record)

        describe(record).merge('role' => enums[relation[:role_id]], 'relator' => enums[relation[:relator_id]])
      end

      records.uniq { |r| [r['uri'], r['role'], r['relator']] }
             .sort_by { |r| [RECORD_ORDER.index(r['jsonmodel_type']) || 99, r['title'].to_s.downcase] }
    end

    def record_published?(record)
      return false unless record.publish == 1 && record.suppressed != 1
      return true unless record.class.respond_to?(:calculate_has_unpublished_ancestor)

      !record.class.calculate_has_unpublished_ancestor(record)
    end

    def describe(record)
      type = record.class.my_jsonmodel.record_type
      described = { 'jsonmodel_type' => type, 'uri' => uri_for(record) }

      case type
      when 'resource'
        described.merge('title' => record.title, 'ead_id' => record.ead_id)
      when 'archival_object'
        resource = Resource.any_repo[record.root_record_id]
        described.merge('title' => record.display_string || record.title, 'ref_id' => record.ref_id,
                        'ead_id' => resource&.ead_id, 'resource_uri' => resource && uri_for(resource))
      when 'digital_object_component'
        described.merge('title' => record.display_string || record.title,
                        'resource_uri' => uri_for(DigitalObject.any_repo[record.root_record_id]))
      else
        described.merge('title' => record.title)
      end
    end

    def uri_for(record)
      record.class.my_jsonmodel.uri_for(record.id, repo_id: record.repo_id)
    end

    def config(key)
      value = AppConfig.has_key?(key) ? AppConfig[key] : nil
      value.to_s.strip.empty? ? nil : value
    end

    def label(enumeration, value)
      translated = I18n.t("enumerations.#{enumeration}.#{value}", default: '')
      translated.to_s.empty? ? RelationTypes.humanize(value) : translated
    end
  end
end
