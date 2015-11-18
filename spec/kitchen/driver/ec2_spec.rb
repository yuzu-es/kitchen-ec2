# -*- encoding: utf-8 -*-
#
# Author:: Tyler Ball (<tball@chef.io>)
#
# Copyright (C) 2015, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "kitchen/driver/ec2"
require "kitchen/provisioner/dummy"
require "kitchen/transport/dummy"
require "kitchen/verifier/dummy"

describe Kitchen::Driver::Ec2 do

  let(:logged_output) { StringIO.new }
  let(:logger)        { Logger.new(logged_output) }
  let(:config)        { { :aws_ssh_key_id => "key", :image_id => "ami-1234567" } }
  let(:platform)      { Kitchen::Platform.new(:name => "fooos-99") }
  let(:transport)     { Kitchen::Transport::Dummy.new }
  let(:generator)     { instance_double(Kitchen::Driver::Aws::InstanceGenerator) }
  # There is too much name overlap I let creep in - my `client` is actually
  # a wrapper around the actual ec2 client
  let(:actual_client) { double("actual ec2 client") }
  let(:client)        { double(Kitchen::Driver::Aws::Client, :client => actual_client) }
  let(:server) { double("aws server object") }
  let(:state) { {} }

  let(:driver) { Kitchen::Driver::Ec2.new(config) }

  let(:instance) do
    instance_double(
      Kitchen::Instance,
      :logger => logger,
      :transport => transport,
      :platform => platform,
      :to_str => "str"
    )
  end

  before do
    allow(Kitchen::Driver::Aws::InstanceGenerator).to receive(:new).and_return(generator)
    allow(Kitchen::Driver::Aws::Client).to receive(:new).and_return(client)
    allow(driver).to receive(:windows_os?).and_return(false)
    allow(driver).to receive(:instance).and_return(instance)
  end

  it "driver api_version is 2" do
    expect(driver.diagnose_plugin[:api_version]).to eq(2)
  end

  it "plugin_version is set to Kitchen::Vagrant::VERSION" do
    expect(driver.diagnose_plugin[:version]).to eq(
      Kitchen::Driver::EC2_VERSION)
  end

  describe "configuration" do
    let(:config) { {} }
    it "requires :aws_ssh_key_id to be provided" do
      expect { driver.finalize_config!(instance) }.to \
        raise_error(Kitchen::UserError, /:aws_ssh_key_id/)
    end

    it "requires :image_id to be provided" do
      config[:aws_ssh_key_id] = "key"
      expect { driver.finalize_config!(instance) }.to \
        raise_error(Kitchen::UserError, /:image_id/)
    end
  end

  describe "#finalize_config!" do
    it "defaults the availability zone if not provided" do
      expect(config[:availability_zone]).to eq(nil)
      driver.finalize_config!(instance)
      expect(config[:availability_zone]).to eq("us-east-1b")
    end

    it "expands the availability zone if provided as a letter" do
      config[:availability_zone] = "d"
      driver.finalize_config!(instance)
      expect(config[:availability_zone]).to eq("us-east-1d")
    end
  end

  describe "#hostname" do
    let(:public_dns_name) { nil }
    let(:public_ip_address) { nil }
    let(:private_ip_address) { nil }
    let(:server) {
      double("server",
        :public_dns_name => public_dns_name,
        :public_ip_address => public_ip_address,
        :private_ip_address => private_ip_address
      )
    }

    it "returns nil if all sources are nil" do
      expect(driver.hostname(server)).to eq(nil)
    end

    it "raises an error if provided an unknown interface" do
      expect { driver.hostname(server, "foobar") }.to raise_error(Kitchen::UserError)
    end

    shared_examples "an interface type provided" do
      it "returns public_dns_name when requested" do
        expect(driver.hostname(server, "dns")).to eq(public_dns_name)
      end
      it "returns public_ip_address when requested" do
        expect(driver.hostname(server, "public")).to eq(public_ip_address)
      end
      it "returns private_ip_address when requested" do
        expect(driver.hostname(server, "private")).to eq(private_ip_address)
      end
    end

    context "private_ip_address is populated" do
      let(:private_ip_address) { "10.0.0.1" }

      it "returns the private_ip_address" do
        expect(driver.hostname(server)).to eq(private_ip_address)
      end

      include_examples "an interface type provided"
    end

    context "public_ip_address is populated" do
      let(:private_ip_address) { "10.0.0.1" }
      let(:public_ip_address) { "127.0.0.1" }

      it "returns the public_ip_address" do
        expect(driver.hostname(server)).to eq(public_ip_address)
      end

      include_examples "an interface type provided"
    end

    context "public_dns_name is populated" do
      let(:private_ip_address) { "10.0.0.1" }
      let(:public_ip_address) { "127.0.0.1" }
      let(:public_dns_name) { "public_dns_name" }

      it "returns the public_dns_name" do
        expect(driver.hostname(server)).to eq(public_dns_name)
      end

      include_examples "an interface type provided"
    end

    context "public_dns_name returns as empty string" do
      let(:public_dns_name) { "" }
      it "returns nil" do
        expect(driver.hostname(server)).to eq(nil)
      end

      context "and private_ip_address is populated" do
        let(:private_ip_address) { "10.0.0.1" }
        it "returns the private_ip_address" do
          expect(driver.hostname(server)).to eq(private_ip_address)
        end
      end
    end
  end

  describe "#submit_server" do
    before do
      expect(driver).to receive(:instance).at_least(:once).and_return(instance)
    end

    it "submits the server request" do
      expect(generator).to receive(:ec2_instance_data).and_return({})
      expect(client).to receive(:create_instance).with(:min_count => 1, :max_count => 1)
      driver.submit_server
    end
  end

  describe "#submit_spot" do
    let(:state) { {} }
    let(:response) {
      { :spot_instance_requests => [{ :spot_instance_request_id => "id" }] }
    }

    before do
      expect(driver).to receive(:instance).at_least(:once).and_return(instance)
    end

    it "submits the server request" do
      expect(generator).to receive(:ec2_instance_data).and_return({})
      expect(actual_client).to receive(:request_spot_instances).with(
        :spot_price => "", :valid_until => nil, :launch_specification => {}
      ).and_return(response)
      expect(actual_client).to receive(:wait_until)
      expect(client).to receive(:get_instance_from_spot_request).with("id")
      driver.submit_spot(state)
      expect(state).to eq(:spot_request_id => "id")
    end
  end

  describe "#tag_server" do
    it "tags the server" do
      config[:tags] = { :key1 => :value1, :key2 => :value2 }
      expect(server).to receive(:create_tags).with(
        :tags => [
          { :key => :key1, :value => :value1 },
          { :key => :key2, :value => :value2 }
        ]
      )
      driver.tag_server(server)
    end
  end

  describe "#wait_until_ready" do
    let(:hostname) { "0.0.0.0" }
    let(:msg) { "to become ready" }
    let(:aws_instance) { double("aws instance") }

    before do
      config[:interface] = :i
      expect(driver).to receive(:wait_with_destroy).with(server, state, msg).and_yield(aws_instance)
      expect(driver).to receive(:hostname).with(aws_instance, :i).and_return(hostname)
    end

    after do
      expect(state[:hostname]).to eq(hostname)
    end

    it "first checks instance existence" do
      expect(aws_instance).to receive(:exists?).and_return(false)
      expect(driver.wait_until_ready(server, state)).to eq(false)
    end

    it "second checks instance state" do
      expect(aws_instance).to receive(:exists?).and_return(true)
      expect(aws_instance).to receive_message_chain("state.name").and_return("nope")
      expect(driver.wait_until_ready(server, state)).to eq(false)
    end

    it "third checks hostname" do
      expect(aws_instance).to receive(:exists?).and_return(true)
      expect(aws_instance).to receive_message_chain("state.name").and_return("running")
      expect(driver.wait_until_ready(server, state)).to eq(false)
    end

    context "when it exists, has a valid state and a valid hostname" do
      let(:hostname) { "host" }

      it "returns true" do
        expect(aws_instance).to receive(:exists?).and_return(true)
        expect(aws_instance).to receive_message_chain("state.name").and_return("running")
        expect(driver.wait_until_ready(server, state)).to eq(true)
      end
    end
  end

  describe "#fetch_windows_admin_password" do
    let(:msg) { "to fetch windows admin password" }
    let(:aws_instance) { double("aws instance") }
    let(:server_id) { "server_id" }
    let(:encrypted_password) { "alksdofw" }
    let(:data) { double("data", :password_data => encrypted_password) }
    let(:password) { "password" }
    let(:transport) { { :ssh_key => "foo" } }

    before do
      state[:server_id] = server_id
      expect(driver).to receive(:wait_with_destroy).with(server, state, msg).and_yield(aws_instance)
    end

    after do
      expect(state[:password]).to eq(password)
    end

    it "fetches and decrypts the windows password" do
      expect(server).to receive_message_chain("client.get_password_data").with(
        :instance_id => server_id
      ).and_return(data)
      expect(server).to receive(:decrypt_windows_password).with("foo").and_return(password)
      driver.fetch_windows_admin_password(server, state)
    end

  end

  describe "#wait_with_destroy" do
    let(:tries) { 111 }
    let(:sleep) { 222 }
    let(:msg) { "msg" }
    given_block = lambda do; end

    before do
      config[:retryable_sleep] = sleep
      config[:retryable_tries] = tries
    end

    it "calls wait and exits successfully if there is no error" do
      expect(server).to receive(:wait_until) do |args, &block|
        expect(args[:max_attempts]).to eq(tries)
        expect(args[:delay]).to eq(sleep)
        expect(block).to eq(given_block)
        expect(driver).to receive(:info).with(/#{msg}/)
        args[:before_attempt].call(0)
      end
      driver.wait_with_destroy(server, state, msg, &given_block)
    end

    it "attempts to destroy the instance if the waiter fails" do
      expect(server).to receive(:wait_until).and_raise(::Aws::Waiters::Errors::WaiterFailed)
      expect(driver).to receive(:destroy).with(state)
      expect(driver).to receive(:error).with(/#{msg}/)
      expect {
        driver.wait_with_destroy(server, state, msg, &given_block)
      }.to raise_error(::Aws::Waiters::Errors::WaiterFailed)
    end
  end

  describe "#create" do
    let(:server) { double("aws server object", :id => id) }
    let(:id) { "i-12345" }

    before do
      expect(driver).to receive(:copy_deprecated_configs).with(state)
    end

    it "returns if the instance is already created" do
      state[:server_id] = id
      expect(driver.create(state)).to eq(nil)
    end

    shared_examples "common create" do
      it "successfully creates and tags the instance" do
        expect(server).to receive(:wait_until_exists)
        expect(driver).to receive(:tag_server).with(server)
        expect(driver).to receive(:wait_until_ready).with(server, state)
        expect(transport).to receive_message_chain("connection.wait_until_ready")
        expect(driver).to receive(:create_ec2_json).with(state)
        driver.create(state)
        expect(state[:server_id]).to eq(id)
      end
    end

    context "non-windows on-depand instance" do
      before do
        expect(driver).to receive(:submit_server).and_return(server)
      end

      include_examples "common create"
    end

    context "config is for a spot instance" do
      before do
        config[:price] = 1
        config[:duration] = 1
        expect(driver).to receive(:submit_spot).with(state).and_return(server)
      end

      include_examples "common create"
    end

    context "instance is a windows machine" do
      before do
        expect(driver).to receive(:windows_os?).and_return(true)
        expect(transport).to receive(:[]).with(:username).and_return("administrator")
        expect(transport).to receive(:[]).with(:password).and_return(nil)
        expect(driver).to receive(:submit_server).and_return(server)
        expect(driver).to receive(:fetch_windows_admin_password).with(server, state)
      end

      include_examples "common create"
    end

  end

  describe "#destroy" do
    context "when state[:server_id] is nil" do
      it "returns nil" do
        expect(driver.destroy(state)).to eq(nil)
      end
    end

    context "when state has a normal server_id" do
      let(:state) { { :server_id => "id", :hostname => "name" } }

      context "the server is already destroyed" do
        it "does nothing" do
          expect(client).to receive(:get_instance).with("id").and_return nil
          driver.destroy(state)
          expect(state).to eq({})
        end
      end

      it "destroys the server" do
        expect(client).to receive(:get_instance).with("id").and_return(server)
        expect(instance).to receive_message_chain("transport.connection.close")
        expect(server).to receive(:terminate)
        driver.destroy(state)
        expect(state).to eq({})
      end
    end

    context "when state has a spot request" do
      let(:state) { { :server_id => "id", :hostname => "name", :spot_request_id => "spot" } }

      it "destroys the server" do
        expect(client).to receive(:get_instance).with("id").and_return(server)
        expect(instance).to receive_message_chain("transport.connection.close")
        expect(server).to receive(:terminate)
        expect(actual_client).to receive(:cancel_spot_instance_requests).with(
          :spot_instance_request_ids => ["spot"]
        )
        driver.destroy(state)
        expect(state).to eq({})
      end
    end
  end

  describe "#lookup_ami" do
    let(:resource) { double("actual resource") }

    let(:filters) { { :name => "ami_name" } }
    let(:aws_filters) do
      { :filters => [{ :name => "name", :values => ["ami_name"] }] }
    end

    before do
      allow(client).to receive(:resource).and_return(resource)
    end

    context "when one ami found" do
      let(:ami_id) { "ami-a1b2c3d4" }
      let(:date) { "2015-06-10T03:47:20.000Z" }
      let(:ami_list) { [double("ami", :id => ami_id, :creation_date => date)] }

      it "returns the ami id" do
        expect(resource).to receive(:images).with(aws_filters). \
          and_return(ami_list)
        expect(driver.lookup_ami(filters)).to eq(ami_id)
      end
    end

    context "when more than one ami found" do
      let(:date_older) { "2015-06-10T03:47:20.000Z" }
      let(:date_newer) { "2015-06-11T03:47:20.000Z" }
      let(:ami_id_older) { "ami-a1b2c3d4" }
      let(:ami_id_newer) { "ami-e5f6g7h8" }
      let(:ami_list) do
        [
          double("ami", :id => ami_id_older, :creation_date => date_older),
          double("ami", :id => ami_id_newer, :creation_date => date_newer)
        ]
      end

      it "returns most recently created ami id" do
        expect(resource).to receive(:images).with(aws_filters). \
          and_return(ami_list)
        expect(driver.lookup_ami(filters)).to eq(ami_id_newer)
      end
    end
  end

  describe "#default_ami" do
    context "when platform is ubuntu" do
      let(:config) { { :aws_ssh_key_id => "key" } }
      let(:platform) { Kitchen::Platform.new(:name => "ubuntu-14.04") }
      let(:ami_data) { %w[ ami-1305ef78 instance-store amd64 us-east-1 paravirtual ] }

      it "queries an ami_id" do
        expect(driver).to receive(:ubuntu_ami).with(config[:region], platform.name). \
          and_return(Ubuntu::Ami.new(*ami_data))
        expect(driver.default_ami).to eq(ami_data[0])
      end
    end

    context "when ami_search is provided" do
      let(:config) { { :image_search => {} } }
      let(:ami_id) { "ami-xxxxxxxx" }

      it "searches for an image id" do
        expect(driver).to receive(:lookup_ami).with(config[:image_search]). \
          and_return(ami_id)
        expect(driver.default_ami).to eq(ami_id)
      end
    end
  end

end
