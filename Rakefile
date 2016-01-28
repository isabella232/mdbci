require 'rake'
require_relative 'spec/rake_helper'

# here you need to add task with appropriate parameters
task :run_parametrized do
  Rake::Task[:task_6639_ssh_exit_code].execute({
    :pathToConfigToVBOXNode=>'TEST/vboxnode',
    :pathToConfigToMDBCINode=>'TEST1/mdbcinode',
    :pathToConfigToMDBCIBadNode=>'TEST2/mdbcinodebad',
    :pathToConfigToMDBCIFolder=>'TEST1'
  })

  RakeTaskManager.get_failed_tests_info
end

# here will be tasks without parameters
task :run do
  Rake::Task[:task_generator].execute

  RakeTaskManager.get_failed_tests_info
end

### EXAMPLE ###
# name of task can not start with digits, so it starts with 'task...'
# this task expecting argument which is hash {:pathToConfig=>'TEST', :vmType=>'mdbci'}
# keys and values will be added to ENV variable for one test then when test is executed
# those keys and values will be removed from ENV
# in this case if you want to run only next task with parameters - you need to define parameters
# like that [:arg1, :arg2, ...] so then in ENV they would be available like ENV['arg1']
# then in cmd: rake task_6639_ssh_exit_code['TEST/vboxnode']
task :task_6639_ssh_exit_code, [:pathToConfigToVBOXNode, :pathToConfigToMDBCINode, :pathToConfigToMDBCIFolder, :pathToConfigToMDBCINode] do |t, args|
  RakeTaskManager.new(t).run_parametrized(args)
end

task :task_generator do |t|
  RakeTaskManager.new(t).run
end