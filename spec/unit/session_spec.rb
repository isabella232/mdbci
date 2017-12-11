# frozen_string_literal: true

require 'rspec'
require_relative '../spec_helper'
require_relative '../../core/session'
require_relative '../../core/node_product'
require_relative '../../core/out'
require_relative '../../core/repo_manager'
require_relative '../../core/exception_handler'

describe 'Session' do
  before :all do
    $mdbci_exec_dir = ENV['WORKSPACE']
    $out = Out.new
    $session = Session.new
    $session.isSilent = true
    $session.mdbciDir = Dir.pwd
    $exception_handler = ExceptionHandler.new
    boxesPath = './BOXES'
    $session.boxes = BoxesManager.new boxesPath
    reposPath = './repo.d'
    $session.repos = RepoManager.new reposPath
  end

  context '.configurationFiles' do
    it 'Check aws config loading...' do
      $mdbci_exec_dir = ENV['WORKSPACE']
      session = Session.new
      session.awsConfigFile = 'aws-config.yml'
      awsConfig = YAML.load_file(session.awsConfigFile)['aws']
      awsConfig.size.should_not eq(0)
    end

    it 'Check template loading...' do
      $mdbci_exec_dir = ENV['WORKSPACE']
      session = Session.new
      session.configFile = 'spec/test_machine_configurations/galera-cnf-template.json'
      nodes = JSON.parse(IO.read(session.configFile))
      # out.out 'Found boxes: ' + boxes.size().to_s
      # boxes is not empty
      nodes.size.should_not eq(0)
      nodes.size.should eq(7)
    end
  end

  context '.getPlatforms' do
    it 'should return array of platforms' do
      fake_box_manager = double
      platforms = %w[first second third]
      boxes = platforms.map do |platform|
        [nil, { Session::PLATFORM => platform }]
      end
      allow(fake_box_manager).to receive(:each).and_yield(boxes[0])
        .and_yield(boxes[1]).and_yield(boxes[2])
      allow(fake_box_manager).to receive(:empty?).and_return(false)
      fake_boxes = double
      allow(fake_boxes).to receive(:boxesManager).and_return(fake_box_manager)
      $session.boxes = fake_boxes
      expect($session.getPlatfroms.sort).to eq(platforms.sort)
    end

    it 'should rise error when boxes are not found' do
      fake_box_manager = double('manager')
      allow(fake_box_manager).to receive(:empty?).and_return(true)
      fake_boxes = double('boxes')
      allow(fake_boxes).to receive(:boxesManager).and_return(fake_box_manager)
      $session.boxes = fake_boxes
      expect { $session.getPlatfroms }.to raise_error 'Boxes are not found'
    end
  end

  context '.getBoxesPlatformVersions' do
    def generate_boxes_for_platform(platform, versions)
      versions.map do |version|
        [nil,
         {
           Session::PLATFORM => platform,
           'platform_version' => version
         }]
      end
    end

    it 'should return empty array if there are no boxes' do
      fake_box_manager = double('manager')
      allow(fake_box_manager).to receive(:each)
      found_versions = $session.getBoxesPlatformVersions('', fake_box_manager)
      expect(found_versions).to be_empty
    end

    it 'should return empty array if there are no boxes for specified platform' do
      fake_box_manager = double('manager')
      boxes = generate_boxes_for_platform('platform-one', %w[one two])
      allow(fake_box_manager).to receive(:each).and_yield(*boxes[0]).and_yield(*boxes[1])
      found_versions = $session.getBoxesPlatformVersions('other-platform', fake_box_manager)
      expect(found_versions).to be_empty
    end

    it 'should provide correct boxes versions' do
      fake_box_manager = double('manager')
      platform = 'ubuntu'
      versions = %w[wily vivid trusty]
      boxes = generate_boxes_for_platform(platform, versions)
      allow(fake_box_manager).to receive(:each).and_yield(*boxes[0]).and_yield(*boxes[1]).and_yield(*boxes[2])
      found_versions = $session.getBoxesPlatformVersions(platform, fake_box_manager)
      expect(found_versions.sort).to eq(versions.sort)
    end

    it 'should remove doubles' do
      fake_box_manager = double('manager')
      platform = 'ubuntu'
      versions = ['vivid']
      boxes = generate_boxes_for_platform(platform, versions)
      allow(fake_box_manager).to receive(:each).and_yield(*boxes[0]).and_yield(*boxes[0])
      found_versions = $session.getBoxesPlatformVersions(platform, fake_box_manager)
      expect(found_versions).to eq(versions)
    end
  end
end
