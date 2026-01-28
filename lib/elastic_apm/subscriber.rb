# Licensed to Elasticsearch B.V. under one or more contributor
# license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# frozen_string_literal: true

require 'active_support/notifications'
require 'elastic_apm/normalizers'

module ElasticAPM
  # @api private
  class Subscriber
    include Logging

    # Events that indicate the start of "real work" (end of rack middleware stack)
    RACK_STACK_ENDING_EVENTS = %w[
      process_action.action_controller
      endpoint_run.grape
    ].freeze

    def initialize(agent)
      @agent = agent
      @normalizers = Normalizers.build(agent.config)
    end

    def register!
      unregister! if @subscription

      @subscription =
        ActiveSupport::Notifications.subscribe(notifications_regex, self)
    end

    def unregister!
      ActiveSupport::Notifications.unsubscribe @subscription
      @subscription = nil
    end

    # AS::Notifications API

    Notification = Struct.new(:id, :span)

    def start(name, id, payload)
      return unless (transaction = @agent.current_transaction)

      # Finalize Rack Stack span when first "real work" event starts
      finish_rack_stack_span_if_needed(transaction, name)

      normalized = @normalizers.normalize(transaction, name, payload)

      span =
        if normalized == :skip
          nil
        else
          name, type, subtype, action, context = normalized

          @agent.start_span(
            name,
            type,
            subtype: subtype,
            action: action,
            context: context
          )
        end

      transaction.notifications << Notification.new(id, span)
    end

    # rubocop:disable Metrics/CyclomaticComplexity
    def finish(name, id, payload)
      # debug "AS::Notification#finish:#{name}:#{id}"
      return unless (transaction = @agent.current_transaction)

      while (notification = transaction.notifications.pop)
        next unless notification.id == id

        if (span = notification.span)
          if @agent.config.span_frames_min_duration?
            span.original_backtrace ||= @normalizers.backtrace(name, payload)
          end
          @agent.end_span if span == @agent.current_span
        end
        return
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity

    private

    def notifications_regex
      @notifications_regex ||= /(#{@normalizers.keys.join('|')})/
    end

    def finish_rack_stack_span_if_needed(transaction, event_name)
      return unless transaction.rack_stack_span
      return unless RACK_STACK_ENDING_EVENTS.include?(event_name)

      ElasticAPM.end_span(transaction.rack_stack_span)
      transaction.rack_stack_span = nil
    end
  end
end
