# Copyright 2013, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

class CreateNetworks < ActiveRecord::Migration
  def change
    create_table "#{BarclampNetwork::TABLE_PREFIX}networks" do |t|
      t.references   :deployment
      t.string       :name,        :null => false, :index => true
      t.integer      :vlan,        :null => false, :default => 0
      t.boolean      :use_vlan,    :null => false, :default => false
      t.boolean      :use_bridge,  :null => false, :default => false
      t.integer      :team_mode,   :null => false, :default => 5
      t.boolean      :use_team,    :null => false, :default => false
      # This contains abstract interface names seperated by a comma.
      # It could be normalized, but why bother for now.
      t.string       :conduit,     :null => false
    end

    create_table "#{BarclampNetwork::TABLE_PREFIX}routers" do |t|
      t.references   :network
      t.string       :address,     :null => false
      t.integer      :pref,        :null => false, :default => 65536
    end

    create_table "#{BarclampNetwork::TABLE_PREFIX}ranges" do |t|
      t.string       :name,        :null => false
      t.references   :network
      # Both of these should also be CIDRs.
      t.string       :first,       :null => false
      t.string       :last,        :null => false
    end

    create_table "#{BarclampNetwork::TABLE_PREFIX}allocations" do |t|
      t.references   :node
      t.references   :range
      t.string       :address,     :null => false, :index => true, :unique => true
    end
  end
end
