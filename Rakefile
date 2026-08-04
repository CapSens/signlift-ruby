require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# bundler/gem_tasks ships a release task that tags and then pushes the built gem
# to rubygems.org. This gem is not published there -- it is consumed straight
# from this repository, pinned to a tag -- so the obvious command would publish
# it by accident. Releasing is the procedure in the README.
Rake::Task["release"].clear
desc "Refuses: this gem is not published on RubyGems"
task :release do
  abort(
    [
      "This gem is not published on RubyGems: consumers install it from this",
      "repository, pinned to a tag. See the Releasing section of the README.",
    ].join(" ")
  )
end

task default: [:spec]
