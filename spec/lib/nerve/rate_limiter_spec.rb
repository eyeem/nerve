require 'spec_helper'
require 'nerve/rate_limiter'
require 'active_support/all'
require 'active_support/testing/time_helpers'

AVERAGE_RATE = 100
MAX_BURST = 500

describe Nerve::RateLimiter do
  include ActiveSupport::Testing::TimeHelpers

  describe 'initialize' do
    it 'can successfully initialize' do
      Nerve::RateLimiter.new(average_rate: AVERAGE_RATE, max_burst: MAX_BURST)
    end

    it 'validates types of arguments' do
      expect {
        Nerve::RateLimiter.new(average_rate: 'string', max_burst: 1)
      }.to raise_error ArgumentError
      expect{
        Nerve::RateLimiter.new(average_rate: 1, max_burst: 'string')
      }.to raise_error ArgumentError
    end

    it 'validates argument constraints' do
      expect {
        Nerve::RateLimiter.new(average_rate: -1, max_burst: 1)
      }.to raise_error ArgumentError
      expect{
        Nerve::RateLimiter.new(average_rate: 1, max_burst: 0)
      }.to raise_error ArgumentError
    end
  end

  describe 'consume' do
    let!(:rate_limiter) {
      Nerve::RateLimiter.new(average_rate: AVERAGE_RATE, max_burst: MAX_BURST)
    }

    context 'when no tokens have been consumed' do
      it 'allows tokens to be consumed' do
        expect(rate_limiter.consume).to be true
      end

      it 'allows up to the maximum burst' do
        # Wait until there are enough tokens to hit the maximum burst
        travel (MAX_BURST / AVERAGE_RATE + 1)

        for _ in 1..MAX_BURST do
          expect(rate_limiter.consume).to be true
        end
      end

      it 'does not allow more than the maximum burst' do
        # Wait until there are enough tokens to hit the maximum burst
        travel (MAX_BURST / AVERAGE_RATE + 1)

        for _ in 1..MAX_BURST do
          rate_limiter.consume
        end

        expect(rate_limiter.consume).to be false
      end
    end

    context 'when all tokens are consumed' do
      before {
        # consume up to the maximum burst
        for _ in 1..MAX_BURST do
          rate_limiter.consume
        end
      }

      it 'does not allow tokens to be consumed' do
        expect(rate_limiter.consume).to be false
      end

      it 'allows token to be consumed next period' do
        travel 1
        expect(rate_limiter.consume).to be true
      end
    end

    context 'when the average rate is infinite' do
      let!(:rate_limiter) {
        Nerve::RateLimiter.new(average_rate: Float::INFINITY, max_burst: MAX_BURST)
      }

      it 'always allows tokens to be consumed' do
        travel_to Time.now

        # Should be able to consume more than the maximum burst
        for _ in 1..(MAX_BURST * 2) do
          expect(rate_limiter.consume).to be true
        end
      end
    end

    it 'only allows average rate over time' do
      start_time = Time.now
      count_success = 0
      num_periods = 250

      # Freeze time unless we manually move it.
      travel_to start_time

      # Clear all existing tokens.
      while rate_limiter.consume do end

      for period in 1..num_periods do
        travel 1

        while rate_limiter.consume
          count_success += 1
        end

        # Only check the average rate after a while, in which the rate will have
        # been sustained enough to have an accurate average.
        if period >= 0.1 * num_periods
          elapsed_time = Time.now - start_time
          avg_rate = count_success / elapsed_time
          expect(avg_rate).to be_within(0.05 * AVERAGE_RATE).of AVERAGE_RATE
        end
      end
    end
  end
end
