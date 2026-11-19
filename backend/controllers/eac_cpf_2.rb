# frozen_string_literal: true

require_relative '../lib/eac_cpf2'

class ArchivesSpaceService < Sinatra::Base
  include ExportHelpers

  # The output contains only published data (see EacCpf2::Publication), the
  # same data the public interface shows, so no permission is required beyond
  # what ArchivesSpace's own EAC-CPF endpoints ask for.
  {
    'people' => 'a person',
    'corporate_entities' => 'a corporate entity',
    'families' => 'a family'
  }.each do |agent_type, description|
    Endpoint.get("/agents/#{agent_type}/:id/eac_cpf_2.xml")
            .description("Get an EAC-CPF 2.0 representation of #{description}, containing published data only")
            .params(['id', :id])
            .permissions([])
            .returns([200, 'EAC-CPF 2.0 XML'],
                     [404, 'The agent does not exist or is not published']) \
    do
      xml_response(EacCpf2::Exporter.export(agent_type, params[:id]))
    end
  end
end
