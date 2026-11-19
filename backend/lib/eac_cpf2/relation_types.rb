# frozen_string_literal: true

module EacCpf2
  # Maps ArchivesSpace relators onto EAC-CPF 2.0 <relationType> values.
  #
  # ArchivesSpace stores an agent relationship from the point of view of the
  # record being fetched: GET A returns {relator: "is_subordinate_to", ref: B}
  # for "A is subordinate to B", and GET B returns the inverse relator for the
  # same relationship. EAC-CPF 2.0 reads <relationType> in the same direction
  # (described entity -> target entity), so the relator is carried over as-is.
  #
  # EAC-CPF 2010 read @cpfRelationType the other way (target -> described
  # entity). ArchivesSpace's built-in exporter maps is_superior_of to
  # "hierarchical-parent" without accounting for that, which is why its
  # hierarchical and temporal relations come out reversed.
  #
  # Terms come from Records in Contexts Ontology (RiC-O) 1.1. Where RiC-O has
  # no equivalent, or the RiC-O property is limited to a domain the
  # relationship does not satisfy, only the label is emitted.
  module RelationTypes
    RICO_NAMESPACE = 'https://www.ica.org/standards/RiC/ontology'
    RICO_VOCABULARY = 'RiC-O'

    Term = Struct.new(:label, :rico_property, :person_only) do
      def value_uri
        rico_property && "#{RICO_NAMESPACE}##{rico_property}"
      end
    end

    AGENT_RELATORS = {
      'is_superior_of' => Term.new('has or had subordinate', 'hasOrHadSubordinate', false),
      'is_subordinate_to' => Term.new('is or was subordinate to', 'isOrWasSubordinateTo', false),
      'is_parent_of' => Term.new('has child', 'hasChild', true),
      'is_child_of' => Term.new('is child of', 'isChildOf', true),
      'is_earlier_form_of' => Term.new('has successor', 'hasSuccessor', false),
      'is_later_form_of' => Term.new('is successor of', 'isSuccessorOf', false),
      'is_associative_with' => Term.new('is agent associated with agent', 'isAgentAssociatedWithAgent', false),
      'is_related_with' => Term.new('has family association with', 'hasFamilyAssociationWith', true),
      'is_identified_with' => Term.new('identity', nil, false),
      'is_hierarchical_with' => Term.new('hierarchical', nil, false),
      'is_temporal_with' => Term.new('temporal', nil, false)
    }.freeze

    RECORD_ROLES = {
      'creator' => Term.new('is creator of', 'isCreatorOf', false),
      'subject' => Term.new('is or was subject of', 'isOrWasSubjectOf', false),
      'source' => Term.new('source', nil, false)
    }.freeze

    module_function

    # @param relator [String] ArchivesSpace relator, read from the described agent
    # @param both_persons [Boolean] whether both ends of the relation are persons
    # @return [Term]
    def for_agent_relator(relator, both_persons:)
      term = AGENT_RELATORS[relator] || Term.new(humanize(relator), nil, false)
      return Term.new(term.label, nil, false) if term.person_only && !both_persons

      term
    end

    # @param role [String] linked_agent_role: creator, subject or source
    def for_record_role(role)
      RECORD_ROLES[role] || Term.new(humanize(role), nil, false)
    end

    def humanize(value)
      value.to_s.tr('_', ' ')
    end
  end
end
