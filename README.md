# aspace-eac-cpf-2

An [ArchivesSpace](https://archivesspace.org) plugin that exports agents as
[EAC-CPF 2.0](https://eac.staatsbibliothek-berlin.de/) (2022), containing
**published data only**.

```
GET /agents/people/:id/eac_cpf_2.xml
GET /agents/corporate_entities/:id/eac_cpf_2.xml
GET /agents/families/:id/eac_cpf_2.xml
```

An unpublished or missing agent returns `404`.

Built for the University of Illinois Library's
ArchivesSpace → [Arcflow](https://github.com/UIUCLibrary/arcflow) →
[Arcuit](https://github.com/UIUCLibrary/arcuit) pipeline, but nothing in it is
specific to Illinois.

## Why not ArchivesSpace's own EAC-CPF export?

ArchivesSpace exports EAC-CPF 2010 at
`/repositories/:repo_id/archival_contexts/...`. As of v4.2.1 that export has
two problems that matter for public discovery.

### Relationships come out reversed

ArchivesSpace stores an agent relationship from the point of view of the
record you are looking at. When you fetch A, "A is subordinate to B" comes back
as `{relator: is_subordinate_to, ref: B}`. When you fetch B, the same
relationship comes back as `is_superior_of` A. The staff interface labels these
accordingly: "Is Subordinate to Related".

EAC-CPF **2010** reads `@cpfRelationType` the *other* way: it is "the type of
relation that the corporate body, person, or family [the target] has to the
entity being described". `hierarchical-parent` means "the target is my
parent".

The built-in serializer
(`backend/app/exporters/serializers/eac.rb`) maps `is_superior_of` and
`is_parent_of` to `hierarchical-parent` without accounting for the change of
direction. Every hierarchical and temporal relationship is therefore reversed.
An office subordinate to the Chancellor is exported as the Chancellor's
superior, and an earlier name as a later one.

EAC-CPF **2.0** reverses the 2010 convention: `<relationType>` describes the
relation from the described entity to the target, which is the way
ArchivesSpace already stores it. This plugin carries the relator over unchanged.
See the SAA TS-EAS subteam's
[relation types analysis](https://github.com/SAA-SDT/TS-EAS-subteam-notes/blob/d3da60ba6903caef322b1062f6cf3d1472887fc2/eaccpf-subteam/working-documents/topics/relations/Topic_relationTypes_20211203.pdf).

SAA's own `eac1-to-eac2.xsl` copies `@cpfRelationType` into `<relationType>`
without changing direction, so converting ArchivesSpace's 2010 output does not
fix this. This plugin serializes from the agent record instead.

### Unpublished data is exported

The built-in serializer's publication check for notes is commented out. It
also does not check related agents or linked records. In the University of
Illinois data that means:

* 5,600 unpublished "Legacy Archon ID" biographical notes (one per agent
  migrated from Archon) are exported as biographical history;
* links to unpublished or suppressed collections and digital objects are
  exported with their titles.

## What is published

The plugin follows the rules of the ArchivesSpace public interface:

| Data | Included when |
|---|---|
| The agent | `publish` is true (otherwise `404`) |
| Notes | `publish` is true |
| Subnotes, subjects | not explicitly unpublished (they inherit from their parent) |
| Places, occupations, functions, topics, external resources | `publish` is true |
| Related agents | the related agent is published |
| Linked collections, archival objects, digital objects | published, not suppressed, and no unpublished or suppressed ancestor |
| Contact details | never |
| Staff usernames | never (synthesized maintenance events name `ArchivesSpace`) |

## Relation types

`<relationType>` uses [RiC-O 1.1](https://www.ica.org/standards/RiC/ontology)
labels and IRIs, read from the described agent to the target. `@localType`
keeps the original ArchivesSpace relator or role so consumers can map it
however they like.

| ArchivesSpace relator | `<relationType>` | RiC-O |
|---|---|---|
| `is_superior_of` | has or had subordinate | `rico:hasOrHadSubordinate` |
| `is_subordinate_to` | is or was subordinate to | `rico:isOrWasSubordinateTo` |
| `is_parent_of` | has child | `rico:hasChild`¹ |
| `is_child_of` | is child of | `rico:isChildOf`¹ |
| `is_earlier_form_of` | has successor | `rico:hasSuccessor` |
| `is_later_form_of` | is successor of | `rico:isSuccessorOf` |
| `is_associative_with` | is agent associated with agent | `rico:isAgentAssociatedWithAgent` |
| `is_related_with` (family) | has family association with | `rico:hasFamilyAssociationWith`¹ |
| `is_identified_with` | identity | — |
| `is_hierarchical_with` | hierarchical | — |
| `is_temporal_with` | temporal | — |

¹ RiC-O limits these to two persons. When either end is a family, the label is
kept and the IRI is left out.

For linked records the role maps to `rico:isCreatorOf` (creator),
`rico:isOrWasSubjectOf` (subject) or plain `source`. A MARC relator, when
present, is a second `<relationType vocabularySource="marcrelator">`.

`isOrWasSubordinateTo` and `hasSuccessor` were chosen over the subteam's
`isChildOf` and `hasAncestor` because RiC-O restricts the latter to persons,
and ArchivesSpace uses subordinate/superior and earlier/later chiefly for
corporate bodies.

## Extension attributes

EAC-CPF 2.0 allows attributes from other namespaces on any element. The plugin
uses `xmlns:aspace="https://github.com/UIUCLibrary/aspace-eac-cpf-2#"` for
ArchivesSpace data that has no EAC-CPF home:

| Attribute | On | Value |
|---|---|---|
| `aspace:sortName` | `nameEntry` | ArchivesSpace's exact heading (`sort_name`), which is what its EAD exports use. ArchivesSpace lets staff override it, so it cannot be rebuilt from the name parts |
| `aspace:authorityId` | `nameEntry` | `authority_id` when it is not a URI (a URI goes in `@valueURI`) |
| `aspace:recordType` | `targetEntity` | `resource`, `archival_object`, `digital_object` or `digital_object_component` |
| `aspace:eadId` | `targetEntity` | EAD ID of the linked collection (for archival objects, of their collection) |
| `aspace:refId` | `targetEntity` | `ref_id` of a linked archival object |
| `aspace:resourceUri` | `targetEntity` | URI of an archival object's collection, or a component's digital object |
| `aspace:certainty` | dates | `date_certainty` |

## Other mappings

* Note text containing EAD inline markup becomes `<span>` (with
  `@localType` set to the EAD element and `@style` to CSS translated from
  `@render`) and `<reference href>`; blank lines and `<p>` separate paragraphs.
* `<control>` always has the required `recordId`, `maintenanceAgency` and
  `maintenanceHistory`. The record ID is the primary record identifier, or the
  agent URI. The agent URI is also given as
  `<otherRecordId localType="archivesspace_uri">`.
* Mandates and legal status notes become `<mandate>`/`<legalStatus>` with the
  note label as the term and the text as a descriptive note. Genders become
  `<demographicDescription localType="gender">`.

## Configuration

All optional, in `config.rb`:

```ruby
AppConfig[:plugins] << 'aspace-eac-cpf-2'

# Maintenance agency, when an agent's record control does not name one
AppConfig[:eac_cpf_2_agency_name] = 'University of Illinois Library'
AppConfig[:eac_cpf_2_agency_code] = 'IU'

# Prefix for @valueURI on related agents and records. Defaults to
# AppConfig[:public_proxy_url].
AppConfig[:eac_cpf_2_base_url] = 'https://archivesspace.example.edu'
```

The endpoints require no permission, like ArchivesSpace's own EAC-CPF
endpoints: they return only what the public interface would show.

## Development

The serializer and publication rules are plain Ruby and are tested outside
ArchivesSpace, against real agent records from the University of Illinois
(`spec/fixtures/agents`) and against the official EAC-CPF 2.0 schema
(`schema/eac-cpf-2.0`, CC0, from
[SAA-SDT/eac-cpf-schema](https://github.com/SAA-SDT/eac-cpf-schema)).

```bash
cd spec && bundle config set --local path ../vendor/bundle && cd ..
BUNDLE_GEMFILE=spec/Gemfile bundle install
BUNDLE_GEMFILE=spec/Gemfile bundle exec rspec
```

The test Gemfile lives in `spec/` because ArchivesSpace merges a plugin's root
`Gemfile` into its own bundle.

To check a running ArchivesSpace with the plugin installed, validating every
document against the schema:

```bash
ASPACE_PASSWORD=... BUNDLE_GEMFILE=spec/Gemfile bundle exec ruby scripts/validate_live.rb \
  --url http://localhost:8089 --user admin --sample 600
```

[UIUCLibrary/aspace_alma_integrations](https://github.com/UIUCLibrary/aspace_alma_integrations/tree/main/docker)
has a Docker stack that runs ArchivesSpace against a copy of a server's
database. Mount this plugin into it and add it to `AppConfig[:plugins]`.

## License

GNU Affero General Public License v3.0 or later. See [LICENSE](LICENSE).
ArchivesSpace is licensed under the Educational Community License 2.0, which
the FSF considers compatible with GPLv3.
