# encoding: utf-8
require 'spec_helper'
require 'shared/client_initializer_behaviour'

describe Ably::Realtime::Client do
  subject do
    Ably::Realtime::Client.new(client_options)
  end

  it_behaves_like 'a client initializer'

  context 'delegation to the Rest Client' do
    let(:client_options) { { api_key: 'appid.keyuid:keysecret' } }

    it 'passes on the options to the initializer' do
      rest_client = instance_double('Ably::Rest::Client', auth: instance_double('Ably::Auth'), options: client_options)
      expect(Ably::Rest::Client).to receive(:new).with(client_options).and_return(rest_client)
      subject
    end

    context 'for attribute' do
      [:environment, :use_tls?, :log_level].each do |attribute|
        specify "##{attribute}" do
          expect(subject.rest_client).to receive(attribute)
          subject.public_send attribute
        end
      end
    end
  end
end
