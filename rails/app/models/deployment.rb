# Copyright 2014, Dell
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
#

class Deployment < ActiveRecord::Base

  ERROR = -1
  PROPOSED = 0
  COMMITTED = 1
  ACTIVE = 2
  STATES = {
    PROPOSED => "proposed",
    COMMITTED => "committed",
    ACTIVE => "active",
    ERROR => "error"
  }

  after_commit :run_if_any_runnable, on: :update
  before_destroy :release_nodes    # also prevent deleting if deployment is a system deployment

  has_many        :deployment_roles,  :dependent => :destroy
  has_many        :roles,             :through => :deployment_roles
  has_many        :attribs,           :through => :roles

  has_many        :node_roles,        :dependent => :destroy
  has_many        :nodes
  belongs_to      :parent,            class_name: "Deployment"

  def self.state_name(s)
    raise("#{state || 'nil'} is not a valid Deployment state!") unless s and STATES.include? s
    I18n.t(STATES[s], :scope=>'node_role.state')
  end

  def state_name(s)
    self.class.state_name(s)
  end

  def self.system
    Deployment.find_by!(system: true)
  end

  # is this a system deployment?
  def system?
    read_attribute("system")
  end

  def available_roles
    Role.active - roles
  end

  def available_nodes
    nodes
  end

  def active?
    committed? &&
      node_roles.not_in_state(NodeRole::ACTIVE).count == 0
  end

  def committed?
    read_attribute('state') == COMMITTED
  end

  def proposed?
    read_attribute('state') == PROPOSED
  end

  def annealable?
    committed? && !active? && !error?
  end

  def proposable?
    !system?
  end

  def error?
    committed? &&
      node_roles.in_state(NodeRole::ERROR).count > 0
  end
  def state
    case
    when proposed? then PROPOSED
    when active? then ACTIVE
    when error? then ERROR
    else COMMITTED
    end
  end

  # returns a hash with all the deployment error status information 
  def status
    node_roles.each { |nr| s[nr.id] = nr.status if nr.error?  }
  end

  def commit
    Deployment.transaction do
      deployment_roles.all.each{|dr|dr.commit if dr.proposed?}
      node_roles.in_state(NodeRole::PROPOSED).each { |nr| nr.commit! }
      if proposed?
        write_attribute("state",COMMITTED)
        save!
      end
    end
    Run.run!
    self
  end

  # attempt to stop a proposal that's in transistion.
  # Do this by changing its state from COMMITTED to PROPOSED.
  def propose
    Deployment.transaction do
      raise "Cannot propose  a system deployment" if system?
      write_attribute("state",PROPOSED)
      save!
    end
  end

  private

  def run_if_any_runnable
    Rails.logger.debug("Deployment: after_commit hook called")
    if node_roles.runnable.count > 0
      Rails.logger.info("Deployment: #{name} is committed, kicking the annealer.")
      Run.run!
    end
  end

  # if we delete a deployment, then reset the nodes to be from the system deployment
  def release_nodes
    if system
      # cannot delete a system deployment
      return false
    else
      # else release all the nodes in the deployment (assign to the system deployment)
      Node.transaction do
        sysid = Deployment.system.id
        nodes.update_all(deployment_id: sysid)
        nodes.each do |n|
          n.deployment_id = system.id
          n.save!
        end
        return true
      end
    end
  end

end
