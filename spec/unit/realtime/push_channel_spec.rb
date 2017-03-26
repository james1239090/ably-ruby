require 'spec_helper'

describe Ably::Realtime::Channel::PushChannel do
  subject { Ably::Realtime::Channel::PushChannel }

  let(:channel_name) { 'unique' }
  let(:client) { double('client').as_null_object }
  let(:channel) { Ably::Realtime::Channel.new(client, channel_name) }

  it 'is constructed with a channel' do
    expect(subject.new(channel)).to be_a(Ably::Realtime::Channel::PushChannel)
  end

  it 'raises an exception if constructed with an invalid type' do
    expect { subject.new(Hash.new) }.to raise_error(ArgumentError)
  end

  it 'exposes the channel as attribute #channel' do
    expect(subject.new(channel).channel).to eql(channel)
  end

  it 'is available in the #push attribute of the channel' do
    expect(channel.push).to be_a(Ably::Realtime::Channel::PushChannel)
    expect(channel.push.channel).to eql(channel)
  end
end