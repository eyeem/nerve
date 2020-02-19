require 'nerve/service_watcher/tcp'
require 'nerve/service_watcher/http'
require 'nerve/service_watcher/noop'
require 'nerve/service_watcher/rabbitmq'
require 'nerve/service_watcher/redis'
require 'nerve/rate_limiter'
require 'nerve/version'

module Nerve
  class ServiceWatcher
    include Utils
    include Logging
    include StatsD

    attr_reader :was_up

    def initialize(service={})
      log.debug "nerve: creating service watcher object"

      # check that we have all of the required arguments
      %w{name instance_id host port}.each do |required|
        raise ArgumentError, "missing required argument #{required} for new service watcher" unless service[required]
      end

      @name = service['name']

      # configure the reporter, which we use for reporting status to the registry
      @reporter = Reporter.new_from_service(service)

      # configure the rate limiter for updates to the reporter
      rate_limit_config = service['rate_limiting'] || {}
      @rate_limiter = RateLimiter.new(average_rate: rate_limit_config.fetch('average_rate', Float::INFINITY),
                                      max_burst: rate_limit_config.fetch('max_burst', Float::INFINITY))
      @rate_limit_shadow_mode = rate_limit_config.fetch('shadow_mode', true)

      # instantiate the checks for this service
      @service_checks = []
      service['checks'] ||= []
      service['checks'].each do |check|
        # checks inherit attributes from the service overall
        check['host'] ||= service['host']
        check['port'] ||= service['port']

        # generate a nice readable name for each check
        check['name'] ||= "#{@name} #{check['type']}-#{check['host']}:#{check['port']}"

        # make sure a type is set
        check['type'] ||= "undefined"

        # require a 3rd-party module if necessary for external checkers
        unless ServiceCheck::CHECKS[check['type']]
          m = check['module'] ? check['module'] : "nerve-watcher-#{check['type']}"
          require m
        end

        # instantiate the check object
        service_check_class = ServiceCheck::CHECKS[check['type']]
        if service_check_class.nil?
          raise ArgumentError,
            "invalid service check type #{check['type']}; valid types: #{ServiceCheck::CHECKS.keys.join(',')}"
        end

        # save the check object
        @service_checks << service_check_class.new(check)
      end

      # how often do we initiate service checks?
      @check_interval = service['check_interval'] || 0.5

      # mock service checks for load testing
      @check_mocked = service['check_mocked'] || false

      # force an initial report on startup
      @was_up = nil

      # when this watcher is started it will store the
      # thread here
      @run_thread = nil
      @should_finish = false

      @max_repeated_report_failures = service['max_repeated_report_failures'] || 10

      log.debug "nerve: created service watcher for #{@name} with #{@service_checks.size} checks"
    end

    def start()
      unless @run_thread
        @run_thread = Thread.new { self.run() }
      else
        log.error "nerve: tried to double start a watcher"
      end
    end

    def stop()
      log.info "nerve: stopping service watch #{@name}"
      @should_finish = true
      return true if @run_thread.nil?

      unclean_shutdown = @run_thread.join(10).nil?
      if unclean_shutdown
        log.error "nerve: unclean shutdown of #{@name}, killing thread"
        Thread.kill(@run_thread)
      end
      @run_thread = nil
      !unclean_shutdown
    end

    def alive?()
      !@run_thread.nil? && @run_thread.alive?
    end

    def run()
      log.info "nerve: starting service watch #{@name}"
      statsd.increment('nerve.watcher.start', tags: ["service_name:#{@name}"])

      @reporter.start()

      repeated_report_failures = 0
      until watcher_should_exit? || repeated_report_failures >= @max_repeated_report_failures
        report_succeeded = check_and_report

        case report_succeeded
        when true
          repeated_report_failures = 0
        when false
          repeated_report_failures += 1
        when nil
          # this case exists for when the request is throttled
          # do nothing
          log.info "nerve: check_and_report returned nil (rate limiter shadow mode: #{@rate_limit_shadow_mode})"
        end

        # wait to run more checks but make sure to exit if $EXIT
        # we avoid sleeping for the entire check interval at once
        # so that nerve can exit promptly if required
        responsive_sleep (@check_interval) { watcher_should_exit? }
      end

      if repeated_report_failures >= @max_repeated_report_failures
        statsd.increment('nerve.watcher.stop', tags: ['stop_avenue:failure', 'stop_location:main_loop', "service_name:#{@name}"])
      else
        statsd.increment('nerve.watcher.stop', tags: ['stop_avenue:clean', 'stop_location:main_loop', "service_name:#{@name}"])
      end
    rescue StandardError => e
      statsd.increment('nerve.watcher.stop', tags: ['stop_avenue:abort', 'stop_location:main_loop', "service_name:#{@name}", "exception_name:#{e.class.name}", "exception_message:#{e.message}"])
      log.error "nerve: error in service watcher #{@name}: #{e.inspect}"
      raise e
    ensure
      log.info "nerve: stopping reporter for #{@name}"
      @reporter.stop
    end

    def check_and_report
      if !@reporter.ping?
        statsd.increment('nerve.watcher.status.ping.count', tags: ["ping_result:fail", "service_name:#{@name}", "nerve_version:#{VERSION}"])

        # If the reporter can't ping, then we do not know the status and must force a new report.
        # We will also skip checking service status since it couldn't be reported
        @was_up = nil
        return false
      end
      statsd.increment('nerve.watcher.status.ping.count', tags: ["ping_result:success", "service_name:#{@name}", "nerve_version:#{VERSION}"])

      # what is the status of the service?
      is_up = check?
      log.debug "nerve: current service status for #{@name} is #{is_up.inspect}"

      report_succeeded = true
      if is_up != @was_up
        if ! @rate_limiter.consume
          log.warn "nerve: service #{@name} throttled (shadow mode: #{@rate_limit_shadow_mode})"
          statsd.increment('nerve.watcher.throttled', tags: ["service_name:#{@name}", "shadow_mode:#{@rate_limit_shadow_mode}"])

          unless @rate_limit_shadow_mode
            # When the request is throttled, ensure that the status is reported
            # the next time around.
            @was_up = nil

            # This returns `nil` (instead of `false`) in order to avoid crashing
            # the service watcher because of repeated failures. `nil` specifically
            # reports that the requests were throttled.
            return nil
          end
        end

        if is_up
          report_succeeded = @reporter.report_up
          if report_succeeded
            log.info "nerve: service #{@name} is now up"
          else
            log.warn "nerve: service #{@name} failed to report up"
          end
        else
          report_succeeded = @reporter.report_down
          if report_succeeded
            log.warn "nerve: service #{@name} is now down"
          else
            log.warn "nerve: service #{@name} failed to report down"
          end
        end

        @was_up = is_up

        if report_succeeded
          statsd.increment('nerve.watcher.status.transition', tags: ["new_status:#{is_up ? "up" : "down"}", "service_name:#{@name}"])
          statsd.increment('nerve.watcher.status.report.count', tags: ["report_result:success", "service_name:#{@name}"])
        else
          statsd.increment('nerve.watcher.status.report.count', tags: ["report_result:fail", "service_name:#{@name}"])
        end
      end

      return report_succeeded
    end

    def check?
      if @check_mocked
        return true
      end
      @service_checks.each do |check|
        up = check.up?
        statsd.increment('nerve.watcher.status.service_check', tags: ["check_result:#{up ? "up" : "down"}", "service_name:#{@name}", "check_name:#{check.name}"])
        return false unless up
      end
      return true
    end

    private
    def watcher_should_exit?
      $EXIT || @should_finish
    end

  end
end
