# frozen_string_literal: true

module EacCpf2
  # Decides what an agent's EAC-CPF may contain, using the same rules as
  # ArchivesSpace's public interface:
  #
  # * the agent itself, its notes, its sub-records (places, occupations,
  #   functions, topics, external resources) and related agents must be
  #   published (publish == true);
  # * subnotes and subjects inherit from their parent unless they are
  #   explicitly unpublished (publish == false);
  # * linked archival records must be published, not suppressed, and have no
  #   unpublished or suppressed ancestor;
  # * contact details are never exported.
  #
  # ArchivesSpace's own EAC-CPF exporter applies none of these rules: its note
  # filter is commented out (backend/app/exporters/serializers/eac.rb).
  module Publication
    STRICT_SUBRECORDS = %w[agent_places agent_occupations agent_functions agent_topics agent_resources].freeze
    NEVER_EXPORTED = %w[agent_contacts].freeze

    module_function

    def published?(record)
      record.is_a?(Hash) && record['publish'] == true
    end

    def not_unpublished?(record)
      !(record.is_a?(Hash) && record['publish'] == false)
    end

    # @param json [Hash] an archival record's JSON (resource, archival_object,
    #   digital_object or digital_object_component)
    def record_published?(json)
      published?(json) && json['suppressed'] != true && json['has_unpublished_ancestor'] != true
    end

    # @param agent [Hash] agent JSON with related_agents and subjects resolved
    # @return [Hash] a deep copy holding only what may be published
    def filter_agent(agent)
      result = deep_copy(agent)
      NEVER_EXPORTED.each { |key| result.delete(key) }

      result['notes'] = Array(result['notes']).select { |note| published?(note) }.map { |note| filter_note(note) }
      STRICT_SUBRECORDS.each do |key|
        result[key] = Array(result[key]).select { |sub| published?(sub) }.map { |sub| filter_subjects(sub) }
      end
      %w[used_languages agent_genders].each do |key|
        result[key] = Array(result[key]).map { |sub| filter_subject_notes(sub) }
      end
      result['related_agents'] = Array(result['related_agents']).select { |rel| published?(rel['_resolved']) }

      result
    end

    def filter_note(note)
      return note unless note['subnotes']

      note.merge('subnotes' => note['subnotes'].select { |sub| not_unpublished?(sub) })
    end

    def filter_subjects(sub)
      sub = filter_subject_notes(sub)
      %w[subjects places].each do |key|
        next unless sub[key]

        sub = sub.merge(key => sub[key].select { |ref| not_unpublished?(ref['_resolved']) })
      end
      sub
    end

    def filter_subject_notes(sub)
      return sub unless sub['notes']

      sub.merge('notes' => sub['notes'].select { |note| not_unpublished?(note) })
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
