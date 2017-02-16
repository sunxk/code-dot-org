require_relative '../../deployment'
require 'cdo/hip_chat'
require 'cdo/rake_utils'
require 'cdo/git_utils'

namespace :build do
  desc 'Builds apps.'
  task :apps do
    Dir.chdir(apps_dir) do
      HipChat.log 'Installing <b>apps</b> dependencies...'
      RakeUtils.npm_install

      if rack_env?(:staging)
        HipChat.log 'Updating <b>apps</b> i18n strings...'
        RakeUtils.system './sync-apps.sh'
      end

      HipChat.log 'Building <b>apps</b>...'
      npm_target = (rack_env?(:development) || ENV['CI']) ? 'build' : 'build:dist'
      RakeUtils.system "npm run #{npm_target}"
    end
  end

  desc 'Builds broken link checker.'
  task :tools do
    Dir.chdir(File.join(tools_dir, "scripts", "brokenLinkChecker")) do
      HipChat.log 'Installing <b>broken link checker</b> dependencies...'
      RakeUtils.npm_install
    end
  end

  desc 'generate static ruby/js files from json config'
  task :shared_constants do
    Dir.chdir(File.join(tools_dir, "scripts")) do
      RakeUtils.system 'ruby', 'generateSharedConstants.rb'
    end
  end

  desc 'Builds dashboard (install gems, migrate/seed db, compile assets).'
  task dashboard: :package do
    Dir.chdir(dashboard_dir) do
      # Unless on production, serve UI test directory
      unless rack_env?(:production)
        RakeUtils.ln_s('../test/ui', dashboard_dir('public', 'ui_test'))
      end

      HipChat.log 'Installing <b>dashboard</b> bundle...'
      RakeUtils.bundle_install

      if CDO.daemon
        HipChat.log 'Migrating <b>dashboard</b> database...'
        RakeUtils.rake 'db:migrate'

        # Update the schema cache file, except for production which always uses the cache.
        unless rack_env?(:production)
          schema_cache_file = dashboard_dir('db/schema_cache.dump')
          RakeUtils.rake 'db:schema:cache:dump' unless ENV['CI']
          if GitUtils.file_changed_from_git?(schema_cache_file)
            # Staging is responsible for committing the authoritative schema cache dump.
            if rack_env?(:staging)
              RakeUtils.system 'git', 'add', schema_cache_file
              HipChat.log 'Committing updated schema_cache.dump file...', color: 'purple'
              RakeUtils.system 'git', 'commit', '-m', '"Update schema cache dump after schema changes."', schema_cache_file
              RakeUtils.git_push
              # The schema dump from the test database should always match that generated by staging.
            elsif rack_env?(:test) && GitUtils.current_branch == 'test'
              raise 'Unexpected database schema difference between staging and test (http://wiki.code.org/display/PROD/Unexpected+database+schema+difference+between+staging+and+test)'
            end
          end
        end

        # Allow developers to skip the time-consuming step of seeding the dashboard DB.
        # Additionally allow skipping when running in CircleCI, as it will be seeded during `rake install`
        if (rack_env?(:development) || ENV['CI']) && CDO.skip_seed_all
          HipChat.log "Not seeding <b>dashboard</b> due to CDO.skip_seed_all...\n"\
              "Until you manually run 'rake seed:all' or disable this flag, you won't\n"\
              "see changes to: videos, concepts, levels, scripts, prize providers, \n "\
              "callouts, hints, secret words, or secret pictures."
        else
          HipChat.log 'Seeding <b>dashboard</b>...'
          HipChat.log 'consider setting "skip_seed_all" in locals.yml if this is taking too long' if rack_env?(:development)
          RakeUtils.rake 'seed:all'
        end
      end

      # Skip asset precompile in development where `config.assets.digest = false`.
      unless rack_env?(:development)
        # Skip cleaning assets in production, to be extra sure we don't break anything.
        # Do clean assets in staging and test, to hopefully expose any bugs where we
        # depend on outdated assets.
        unless rack_env?(:production)
          HipChat.log 'Cleaning <b>dashboard</b> assets...'
          RakeUtils.rake 'assets:clean'
        end
        HipChat.log 'Precompiling <b>dashboard</b> assets...'
        RakeUtils.rake 'assets:precompile'
      end

      HipChat.log 'Upgrading <b>dashboard</b>.'
      RakeUtils.upgrade_service CDO.dashboard_unicorn_name unless rack_env?(:development)

      if rack_env?(:production)
        RakeUtils.rake "honeybadger:deploy TO=#{rack_env} REVISION=`git rev-parse HEAD`"
      end
    end
  end

  desc 'Builds pegasus (install gems, migrate/seed db).'
  task :pegasus do
    Dir.chdir(pegasus_dir) do
      HipChat.log 'Installing <b>pegasus</b> bundle...'
      RakeUtils.bundle_install
      if CDO.daemon
        HipChat.log 'Migrating <b>pegasus</b> database...'
        begin
          RakeUtils.rake 'db:migrate'
        rescue => e
          HipChat.log "/quote #{e.message}\n#{CDO.backtrace e}", message_format: 'text'
          raise e
        end

        HipChat.log 'Seeding <b>pegasus</b>...'
        begin
          RakeUtils.rake 'seed:migrate'
        rescue => e
          HipChat.log "/quote #{e.message}\n#{CDO.backtrace e}", message_format: 'text'
          raise e
        end
      end

      HipChat.log 'Upgrading <b>pegasus</b>.'
      RakeUtils.upgrade_service CDO.pegasus_unicorn_name unless rack_env?(:development)
    end
  end

  task :restart_process_queues do
    if CDO.daemon
      HipChat.log 'Restarting <b>process_queues</b>...'
      RakeUtils.restart_service 'process_queues'
    end
  end

  tasks = []
  tasks << :shared_constants
  tasks << :apps if CDO.build_apps
  tasks << :dashboard if CDO.build_dashboard
  tasks << :pegasus if CDO.build_pegasus
  tasks << :tools if rack_env?(:staging)
  tasks << :restart_process_queues if CDO.daemon
  task all: tasks
end

desc 'Builds everything.'
task :build do
  HipChat.wrap('build') { Rake::Task['build:all'].invoke }
end
