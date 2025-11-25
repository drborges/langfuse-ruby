# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::RailsCacheAdapter do
  let(:ttl) { 60 }
  let(:stale_ttl) { 120 }
  let(:refresh_threads) { 2 }
  let(:rails_cache) { double("Rails.cache") }

  before do
    stub_const("Rails", double("Rails", cache: rails_cache))
    allow(rails_cache).to receive_messages(read: nil, write: true, delete: true, delete_matched: true)
    # Skip shutdown - let GC handle it to avoid test interference
  end

  describe "#initialize" do
    context "with SWR enabled" do
      it "creates a thread pool" do
        adapter = described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads)
        expect(adapter.thread_pool).not_to be_nil
        expect(adapter.stale_ttl).to eq(stale_ttl)
      end
    end

    context "without SWR" do
      it "does not create a thread pool" do
        adapter = described_class.new(ttl: ttl)
        expect(adapter.thread_pool).to be_nil
      end
    end
  end

  describe "#fetch_with_stale_while_revalidate" do
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }
    let(:adapter_without_swr) { described_class.new(ttl: ttl) }

    context "when SWR is disabled" do
      it "falls back to fetch_with_lock" do
        cache_key = "test_key"
        new_data = "new_value"
        expect(adapter_without_swr).to receive(:fetch_with_lock).with(cache_key)
        adapter_without_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
      end
    end

    context "with fresh cache entry" do
      it "returns cached data immediately" do
        cache_key = "test_key"
        fresh_data = "fresh_value"
        new_data = "new_value"

        fresh_entry = {
          "data" => fresh_data,
          "fresh_until" => Time.now + 30,
          "stale_until" => Time.now + 150
        }

        allow(adapter_with_swr).to receive(:get_entry_with_metadata)
          .with(cache_key)
          .and_return(fresh_entry)

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
        expect(result).to eq(fresh_data)
      end

      it "does not trigger background refresh" do
        cache_key = "test_key"
        fresh_data = "fresh_value"
        new_data = "new_value"

        fresh_entry = {
          "data" => fresh_data,
          "fresh_until" => Time.now + 30,
          "stale_until" => Time.now + 150
        }

        allow(adapter_with_swr).to receive(:get_entry_with_metadata)
          .with(cache_key)
          .and_return(fresh_entry)

        expect(adapter_with_swr).not_to receive(:schedule_refresh)
        adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
      end
    end

    context "with stale entry (revalidate state)" do
      it "returns stale data immediately" do
        cache_key = "test_key"
        stale_data = "stale_value"
        new_data = "new_value"

        stale_entry = {
          "data" => stale_data,
          "fresh_until" => Time.now - 30, # Expired
          "stale_until" => Time.now + 90  # Still within grace period
        }

        allow(adapter_with_swr).to receive(:get_entry_with_metadata)
          .with(cache_key)
          .and_return(stale_entry)
        allow(adapter_with_swr).to receive(:schedule_refresh)

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
        expect(result).to eq(stale_data)
      end

      it "schedules background refresh" do
        cache_key = "test_key"
        stale_data = "stale_value"
        new_data = "new_value"

        stale_entry = {
          "data" => stale_data,
          "fresh_until" => Time.now - 30, # Expired
          "stale_until" => Time.now + 90  # Still within grace period
        }

        allow(adapter_with_swr).to receive(:get_entry_with_metadata)
          .with(cache_key)
          .and_return(stale_entry)

        expect(adapter_with_swr).to receive(:schedule_refresh).with(cache_key)
        adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
      end
    end

    context "with expired entry (past stale period)" do
      it "fetches fresh data synchronously" do
        cache_key = "test_key"
        stale_data = "stale_value"
        new_data = "new_value"

        expired_entry = {
          "data" => stale_data,
          "fresh_until" => Time.now - 150, # Expired
          "stale_until" => Time.now - 30   # Past grace period
        }

        allow(adapter_with_swr).to receive(:get_entry_with_metadata)
          .with(cache_key)
          .and_return(expired_entry)

        expect(adapter_with_swr).to receive(:fetch_and_cache_with_metadata)
          .with(cache_key)
          .and_return(new_data)

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
        expect(result).to eq(new_data)
      end

      it "does not schedule background refresh" do
        cache_key = "test_key"
        stale_data = "stale_value"
        new_data = "new_value"

        expired_entry = {
          "data" => stale_data,
          "fresh_until" => Time.now - 150, # Expired
          "stale_until" => Time.now - 30   # Past grace period
        }

        allow(adapter_with_swr).to receive(:get_entry_with_metadata)
          .with(cache_key)
          .and_return(expired_entry)
        allow(adapter_with_swr).to receive(:fetch_and_cache_with_metadata)
          .with(cache_key)
          .and_return(new_data)

        expect(adapter_with_swr).not_to receive(:schedule_refresh)
        adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
      end
    end

    context "with cache miss" do
      it "fetches fresh data synchronously" do
        cache_key = "test_key"
        new_data = "new_value"

        allow(adapter_with_swr).to receive(:get_entry_with_metadata)
          .with(cache_key)
          .and_return(nil)

        expect(adapter_with_swr).to receive(:fetch_and_cache_with_metadata)
          .with(cache_key)
          .and_return(new_data)

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
        expect(result).to eq(new_data)
      end
    end
  end

  describe "#schedule_refresh" do
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }

    context "when refresh lock is acquired" do
      it "schedules refresh in thread pool" do
        cache_key = "test_key"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"

        allow(adapter_with_swr).to receive(:acquire_refresh_lock)
          .with(refresh_lock_key)
          .and_return(true)
        allow(adapter_with_swr).to receive(:set_with_metadata)
        allow(adapter_with_swr).to receive(:release_lock)
        # Mock thread pool to execute immediately for testing
        allow(adapter_with_swr.thread_pool).to receive(:post).and_yield

        expect(adapter_with_swr).to receive(:set_with_metadata)
          .with(cache_key, "refreshed_value")

        adapter_with_swr.send(:schedule_refresh, cache_key) { "refreshed_value" }
      end

      it "releases the refresh lock after completion" do
        cache_key = "test_key"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"

        allow(adapter_with_swr).to receive(:acquire_refresh_lock)
          .with(refresh_lock_key)
          .and_return(true)
        allow(adapter_with_swr).to receive(:set_with_metadata)
        allow(adapter_with_swr.thread_pool).to receive(:post).and_yield

        expect(adapter_with_swr).to receive(:release_lock)
          .with(refresh_lock_key)

        adapter_with_swr.send(:schedule_refresh, cache_key) { "refreshed_value" }
      end

      it "releases the refresh lock even if block raises" do
        cache_key = "test_key"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"

        allow(adapter_with_swr).to receive(:acquire_refresh_lock)
          .with(refresh_lock_key)
          .and_return(true)
        allow(adapter_with_swr.thread_pool).to receive(:post).and_yield

        expect(adapter_with_swr).to receive(:release_lock)
          .with(refresh_lock_key)

        expect do
          adapter_with_swr.send(:schedule_refresh, cache_key) { raise "test error" }
        end.to raise_error("test error")
      end
    end

    context "when refresh lock is not acquired" do
      it "does not schedule refresh" do
        cache_key = "test_key"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"

        allow(adapter_with_swr).to receive(:acquire_refresh_lock)
          .with(refresh_lock_key)
          .and_return(false)

        expect(adapter_with_swr.thread_pool).not_to receive(:post)
        adapter_with_swr.send(:schedule_refresh, cache_key) { "refreshed_value" }
      end
    end
  end

  describe "#get_entry_with_metadata" do
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }

    context "when metadata exists" do
      it "returns parsed metadata with symbolized keys" do
        cache_key = "test_key"
        namespaced_metadata_key = "langfuse:#{cache_key}:metadata"
        fresh_until_time = Time.now + 30
        stale_until_time = Time.now + 150

        metadata_json = {
          "data" => "test_value",
          "fresh_until" => fresh_until_time.to_s,
          "stale_until" => stale_until_time.to_s
        }.to_json

        allow(rails_cache).to receive(:read)
          .with(namespaced_metadata_key)
          .and_return(metadata_json)

        result = adapter_with_swr.send(:get_entry_with_metadata, cache_key)

        expect(result).to be_a(Hash)
        expect(result["data"]).to eq("test_value")
        expect(result["fresh_until"]).to be_a(Time)
        expect(result["stale_until"]).to be_a(Time)
      end
    end

    context "when metadata does not exist" do
      it "returns nil" do
        cache_key = "test_key"
        namespaced_metadata_key = "langfuse:#{cache_key}:metadata"

        allow(rails_cache).to receive(:read)
          .with(namespaced_metadata_key)
          .and_return(nil)

        result = adapter_with_swr.send(:get_entry_with_metadata, cache_key)
        expect(result).to be_nil
      end
    end

    context "when metadata is invalid JSON" do
      it "returns nil" do
        cache_key = "test_key"
        namespaced_metadata_key = "langfuse:#{cache_key}:metadata"

        allow(rails_cache).to receive(:read)
          .with(namespaced_metadata_key)
          .and_return("invalid json")

        result = adapter_with_swr.send(:get_entry_with_metadata, cache_key)
        expect(result).to be_nil
      end
    end
  end

  describe "#set_with_metadata" do
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }

    it "stores both value and metadata with correct TTL" do
      cache_key = "test_key"
      value = "test_value"
      namespaced_key = "langfuse:#{cache_key}"
      namespaced_metadata_key = "langfuse:#{cache_key}:metadata"
      total_ttl = ttl + stale_ttl

      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      expect(rails_cache).to receive(:write)
        .with(namespaced_key, value, expires_in: total_ttl)

      expect(rails_cache).to receive(:write)
        .with(namespaced_metadata_key, anything, expires_in: total_ttl)

      result = adapter_with_swr.send(:set_with_metadata, cache_key, value)
      expect(result).to eq(value)
    end

    it "stores metadata with correct timestamps" do
      cache_key = "test_key"
      value = "test_value"
      namespaced_metadata_key = "langfuse:#{cache_key}:metadata"
      total_ttl = ttl + stale_ttl

      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      expected_metadata = {
        "data" => value,
        "fresh_until" => freeze_time + ttl,
        "stale_until" => freeze_time + ttl + stale_ttl
      }.to_json

      expect(rails_cache).to receive(:write)
        .with(namespaced_metadata_key, expected_metadata, expires_in: total_ttl)

      adapter_with_swr.send(:set_with_metadata, cache_key, value)
    end
  end

  describe "#acquire_refresh_lock" do
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }

    context "when lock is available" do
      it "acquires the lock and returns true" do
        lock_key = "langfuse:test_key:refreshing"

        allow(rails_cache).to receive(:write)
          .with(lock_key, true, unless_exist: true, expires_in: 60)
          .and_return(true)

        result = adapter_with_swr.send(:acquire_refresh_lock, lock_key)
        expect(result).to be true
      end
    end

    context "when lock is already held" do
      it "fails to acquire lock and returns false" do
        lock_key = "langfuse:test_key:refreshing"

        allow(rails_cache).to receive(:write)
          .with(lock_key, true, unless_exist: true, expires_in: 60)
          .and_return(false)

        result = adapter_with_swr.send(:acquire_refresh_lock, lock_key)
        expect(result).to be false
      end
    end
  end

  describe "#shutdown" do
    it "shuts down the thread pool gracefully" do
      adapter = described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads)
      thread_pool = adapter.thread_pool
      expect(thread_pool).to receive(:shutdown).once
      expect(thread_pool).to receive(:wait_for_termination).with(5).once

      adapter.shutdown
    end

    context "when no thread pool exists" do
      it "does not raise an error" do
        adapter = described_class.new(ttl: ttl)
        expect { adapter.shutdown }.not_to raise_error
      end
    end
  end

  # Integration test: full SWR cycle
  describe "SWR integration" do
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }

    # rubocop:disable RSpec/ExampleLength
    it "handles complete SWR lifecycle" do
      integration_cache_key = "integration_test"
      memory_cache = {}
      initial_value = "initial"
      updated_value = "updated"

      # Setup memory cache mock
      allow(rails_cache).to receive(:read) { |key| memory_cache[key] }
      allow(rails_cache).to receive(:write) do |key, value, _options|
        memory_cache[key] = value
        true
      end
      allow(rails_cache).to receive(:delete) { |key| memory_cache.delete(key) }

      # Create fetch proc
      fetch_count = 0
      fetch_proc = proc do
        fetch_count += 1
        fetch_count == 1 ? initial_value : updated_value
      end

      # 1. First fetch - cache miss, should fetch and cache
      result1 = adapter_with_swr.fetch_with_stale_while_revalidate(integration_cache_key, &fetch_proc)
      expect(result1).to eq(initial_value)

      # 2. Simulate stale state and background refresh
      allow(adapter_with_swr.thread_pool).to receive(:post).and_yield

      # Simulate stale cache entry
      stale_entry = {
        "data" => initial_value,
        "fresh_until" => (Time.now - 30).to_s, # Past fresh time
        "stale_until" => (Time.now + 90).to_s # Still within stale period
      }
      memory_cache["langfuse:#{integration_cache_key}:metadata"] = stale_entry.to_json

      result2 = adapter_with_swr.fetch_with_stale_while_revalidate(integration_cache_key, &fetch_proc)
      expect(result2).to eq(initial_value) # Returns stale data immediately

      # 3. Simulate completed background refresh
      fresh_entry = {
        "data" => updated_value,
        "fresh_until" => (Time.now + 60).to_s,
        "stale_until" => (Time.now + 150).to_s
      }
      memory_cache["langfuse:#{integration_cache_key}"] = updated_value
      memory_cache["langfuse:#{integration_cache_key}:metadata"] = fresh_entry.to_json

      result3 = adapter_with_swr.fetch_with_stale_while_revalidate(integration_cache_key, &fetch_proc)
      expect(result3).to eq(updated_value)
    end
    # rubocop:enable RSpec/ExampleLength
  end
end
