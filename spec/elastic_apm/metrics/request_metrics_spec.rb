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

require 'spec_helper'
require 'elastic_apm/metrics/request_metrics'
require 'stringio'

module ElasticAPM
  RSpec.describe RequestMetrics do
    let(:base_env) do
      {
        "HTTP_X_REQUEST_ID" => "test-request-123",
        "rack.input" => StringIO.new("test body"),
        "puma.request_body_wait" => 10
      }
    end

    describe '#initialize' do
      it 'extracts request_id from env' do
        metrics = described_class.new(base_env)
        expect(metrics.request_id).to eq "test-request-123"
      end

      it 'extracts body size from rack.input' do
        metrics = described_class.new(base_env)
        expect(metrics.size).to eq 9 # "test body".length
      end

      it 'extracts network_time from puma.request_body_wait' do
        metrics = described_class.new(base_env)
        expect(metrics.network_time).to eq 10
      end

      it 'handles missing rack.input size method' do
        env = base_env.merge("rack.input" => Object.new)
        metrics = described_class.new(env)
        expect(metrics.size).to eq 0
      end

      it 'handles missing puma.request_body_wait' do
        env = base_env.dup
        env.delete("puma.request_body_wait")
        metrics = described_class.new(env)
        expect(metrics.network_time).to eq 0
      end
    end

    describe '#started_at' do
      context 'when HTTP_X_REQUEST_START is not present' do
        it 'returns nil' do
          metrics = described_class.new(base_env)
          expect(metrics.started_at).to be_nil
        end
      end

      context 'with fractional seconds (NGINX format)' do
        it 'parses correctly' do
          timestamp = Time.now.to_f
          env = base_env.merge("HTTP_X_REQUEST_START" => timestamp.to_s)
          metrics = described_class.new(env)

          expect(metrics.started_at).to be_within(0.001).of(Time.at(timestamp))
        end

        it 'handles t= prefix (NGINX format)' do
          timestamp = Time.now.to_f
          env = base_env.merge("HTTP_X_REQUEST_START" => "t=#{timestamp}")
          metrics = described_class.new(env)

          expect(metrics.started_at).to be_within(0.001).of(Time.at(timestamp))
        end
      end

      context 'with whole milliseconds (Heroku format)' do
        it 'parses correctly' do
          timestamp_ms = (Time.now.to_f * 1000).to_i
          env = base_env.merge("HTTP_X_REQUEST_START" => timestamp_ms.to_s)
          metrics = described_class.new(env)

          expect(metrics.started_at).to be_within(1).of(Time.at(timestamp_ms / 1000.0))
        end
      end

      context 'with whole microseconds' do
        it 'parses correctly' do
          timestamp_us = (Time.now.to_f * 1_000_000).to_i
          env = base_env.merge("HTTP_X_REQUEST_START" => timestamp_us.to_s)
          metrics = described_class.new(env)

          expect(metrics.started_at).to be_within(0.001).of(Time.at(timestamp_us / 1_000_000.0))
        end
      end

      context 'with whole nanoseconds (Render format)' do
        it 'parses correctly' do
          timestamp_ns = (Time.now.to_f * 1_000_000_000).to_i
          env = base_env.merge("HTTP_X_REQUEST_START" => timestamp_ns.to_s)
          metrics = described_class.new(env)

          expect(metrics.started_at).to be_within(0.001).of(Time.at(timestamp_ns / 1_000_000_000.0))
        end
      end
    end

    describe '#queue_time' do
      context 'when started_at is nil' do
        it 'returns 0.0' do
          metrics = described_class.new(base_env)
          expect(metrics.queue_time).to eq 0.0
        end
      end

      context 'when started_at is present' do
        it 'calculates queue time in milliseconds' do
          # Set request start to 100ms ago
          timestamp = Time.now.to_f - 0.1
          env = base_env.merge(
            "HTTP_X_REQUEST_START" => timestamp.to_s,
            "puma.request_body_wait" => 0
          )
          metrics = described_class.new(env)

          # Queue time should be approximately 100ms
          expect(metrics.queue_time).to be_within(20).of(100)
        end

        it 'subtracts network_time from queue_time' do
          # Set request start to 100ms ago
          timestamp = Time.now.to_f - 0.1
          env = base_env.merge(
            "HTTP_X_REQUEST_START" => timestamp.to_s,
            "puma.request_body_wait" => 50 # 50ms network wait
          )
          metrics = described_class.new(env)

          # Queue time should be approximately 50ms (100ms - 50ms network)
          expect(metrics.queue_time).to be_within(20).of(50)
        end

        it 'returns 0 for negative queue times' do
          # Set request start to the future (simulating clock skew)
          timestamp = Time.now.to_f + 1.0
          env = base_env.merge("HTTP_X_REQUEST_START" => timestamp.to_s)
          metrics = described_class.new(env)

          expect(metrics.queue_time).to eq 0
        end
      end
    end

    describe '#queue_time_micros' do
      it 'returns queue_time in microseconds' do
        # Set request start to 100ms ago
        timestamp = Time.now.to_f - 0.1
        env = base_env.merge(
          "HTTP_X_REQUEST_START" => timestamp.to_s,
          "puma.request_body_wait" => 0
        )
        metrics = described_class.new(env)

        # Queue time should be approximately 100,000 microseconds
        expect(metrics.queue_time_micros).to be_within(20_000).of(100_000)
      end

      it 'returns 0 when no request start header' do
        metrics = described_class.new(base_env)
        expect(metrics.queue_time_micros).to eq 0
      end
    end

    describe 'timestamp cutoff constants' do
      it 'has correct MILLISECONDS_CUTOFF' do
        # Should be approximately year 2000 in milliseconds
        expect(described_class::MILLISECONDS_CUTOFF).to eq(Time.new(2000, 1, 1).to_i * 1000)
      end

      it 'has correct MICROSECONDS_CUTOFF' do
        expect(described_class::MICROSECONDS_CUTOFF).to eq(described_class::MILLISECONDS_CUTOFF * 1000)
      end

      it 'has correct NANOSECONDS_CUTOFF' do
        expect(described_class::NANOSECONDS_CUTOFF).to eq(described_class::MICROSECONDS_CUTOFF * 1000)
      end
    end
  end
end
