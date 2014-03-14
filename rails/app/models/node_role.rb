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

require 'json'

class NodeRole < ActiveRecord::Base

  after_commit :run_on_todo, on: :update

  belongs_to      :node
  belongs_to      :role
  belongs_to      :snapshot
  has_one         :deployment,        :through => :snapshot
  has_one         :barclamp,          :through => :role
  has_many        :attribs,           :through => :role
  has_many        :runs,              :dependent => :destroy
  has_many        :node_role_data,    :dependent => :destroy, :order => "id DESC"

  # find other node-roles in this snapshot using their role or node
  scope           :all_by_state,      ->(state) { where(['node_roles.state=?', state]) }
  # A node is runnable if:
  # It is in TODO.
  # It is in a committed snapshot.
  scope           :archived,          -> { joins(:snapshot).where('snapshots.state' => Snapshot::ARCHIVED) }
  scope           :current,           -> { joins(:snapshot).where(['snapshots.state != ?',Snapshot::ARCHIVED]).readonly(false) }
  scope           :committed,         -> { joins(:snapshot).where('snapshots.state' => Snapshot::COMMITTED).readonly(false) }
  scope           :deactivatable,     -> { where(:state => [ACTIVE, TRANSITION, ERROR]) }
  scope           :in_state,          ->(state) { where('node_roles.state' => state) }
  scope           :not_in_state,      ->(state) { where(['node_roles.state != ?',state]) }
  scope           :available,         -> { where(:available => true) }
  scope           :runnable,          -> { available.committed.in_state(NodeRole::TODO).joins(:node).where('nodes.alive' => true, 'nodes.available' => true).joins(:role).joins('inner join jigs on jigs.name = roles.jig_name').readonly(false).where(['node_roles.node_id not in (select node_roles.node_id from node_roles where node_roles.state in (?, ?))',TRANSITION,ERROR]) }
  scope           :committed_by_node, ->(node) { where(['state<>? AND state<>? AND node_id=?', NodeRole::PROPOSED, NodeRole::ACTIVE, node.id])}
  scope           :in_snapshot,       ->(snap) { where(:snapshot_id => snap.id) }
  scope           :with_role,         ->(r) { where(:role_id => r.id) }
  scope           :on_node,           ->(n) { where(:node_id => n.id) }
  scope           :peers_by_state,    ->(ss,state) { in_snapshot(ss).in_state(state) }
  scope           :peers_by_role,     ->(ss,role)  { in_snapshot(ss).with_role(role) }
  scope           :peers_by_node,     ->(ss,node)  { in_snapshot(ss).on_node(node) }
  scope           :peers_by_node_and_role,     ->(s,n,r) { peers_by_node(s,n).with_role(r) }
  scope           :snap_node_role,    ->(s,n,r) { where(['snapshot_id=? AND node_id=? AND role_id=?', s.id, n.id, r.id]) }

  # make sure that new node-roles have require upstreams
  # validate        :deployable,        :if => :deployable?
  # node_role_pcms maps parent noderoles to child noderoles.
  has_and_belongs_to_many(:parents,
                          :class_name => "NodeRole",
                          :join_table => "node_role_pcms",
                          :foreign_key => "child_id",
                          :association_foreign_key => "parent_id",
                          :order => "cohort DESC")
  has_and_belongs_to_many(:children,
                          :class_name => "NodeRole",
                          :join_table => "node_role_pcms",
                          :foreign_key => "parent_id",
                          :association_foreign_key => "child_id",
                          :order => "cohort ASC")
  # node_role_all_pcms is a view that expands node_role_pcms
  # to include all of the parents and children of a noderole,
  # recursively.
  has_and_belongs_to_many(:all_parents,
                          :class_name => "NodeRole",
                          :join_table => "node_role_all_pcms",
                          :foreign_key => "child_id",
                          :association_foreign_key => "parent_id",
                          :order => "cohort DESC",
                          :delete_sql => "SELECT 1")
  has_and_belongs_to_many(:all_children,
                          :class_name => "NodeRole",
                          :join_table => "node_role_all_pcms",
                          :foreign_key => "parent_id",
                          :association_foreign_key => "child_id",
                          :order => "cohort ASC",
                          :delete_sql => "SELECT 1")

  # State transitions:
  # All node roles start life in the PROPOSED state.
  # At snapshot commit time, all node roles in PROPOSED that:
  #  1. Have no parent node role, or
  #  2. Have a parent in ACTIVE state
  # will be placed in TODO state, and all others will be placed in BLOCKED.
  #
  # The annealer will then find all node roles in the TODO state, set them
  # to TRANSITION, and hand them over to their appropriate jigs.
  #
  # If the operation for the node role succeeds, the jig will set the
  # node_role to ACTIVE, set all the node_role's BLOCKED children to TODO, and
  # wake up the annealer for another pass.
  #
  # If the operation for the node role fails, the jig will set the node_role to
  # ERROR, set all of its children (recursively) to BLOCKED, and no further
  # processing for that node role dependency tree will happen.

  ERROR      = -1
  ACTIVE     =  0
  TODO       =  1
  TRANSITION =  2
  BLOCKED    =  3
  PROPOSED   =  4
  STATES     = {
    ERROR => 'error',
    ACTIVE => 'active',
    TODO => 'todo',
    TRANSITION => 'transition',
    BLOCKED => 'blocked',
    PROPOSED => 'proposed'
  }

  after_create :create_initial_datum

  class InvalidTransition < Exception
    def initialize(node_role,from,to,str=nil)
      @errstr = "#{node_role.name}: Invalid state transition from #{NodeRole.state_name(from)} to #{NodeRole.state_name(to)}"
      @errstr += ": #{str}" if str
    end
    def to_s
      @errstr
    end

    def to_str
      to_s
    end
  end

  class InvalidState < Exception
  end

  class MissingJig < Exception
    def initalize(nr)
      @errstr = "NodeRole #{nr.name}: Missing jig #{nr.jig_name}"
    end
    def to_s
      @errstr
    end
    def to_str
      to_s
    end
  end

  # lookup i18n version of state
  def state_name
    NodeRole.state_name(state)
  end

  def self.state_name(state)
    raise InvalidState.new("#{state || 'nil'} is not a valid NodeRole state!") unless state and STATES.include? state
    I18n.t(STATES[state], :scope=>'node_role.state')
  end

  def state
    read_attribute("state")
  end

  def error?
    state == ERROR
  end

  def active?
    state == ACTIVE
  end

  def todo?
    state == TODO
  end

  def transition?
    state == TRANSITION
  end

  def blocked?
    state == BLOCKED
  end

  def proposed?
    state == PROPOSED
  end

  def activatable?
    (parents.current.count == 0) ||
      (parents.current.not_in_state(ACTIVE).count == 0)
  end

  def runnable?
    node.available && node.alive && jig.active && snapshot.committed?
  end

  # convenience methods
  def name
    "#{deployment.name}: #{node.name}: #{role.name}" rescue I18n.t('unknown')
  end

  def deployment_role
    DeploymentRole.find_by(snapshot_id: snapshot_id,
                           role_id: role_id)
  end

  def deployment_data
    res = {}
    dr = deployment_role
    res.deep_merge!(dr.data)
    res.deep_merge!(dr.wall)
    res
  end

  def available
    read_attribute("available")
  end

  def available=(b)
    NodeRole.transaction do
      write_attribute("available",!!b)
      save!
    end
  end

  def add_parent(new_parent)
    return if parents.any?{|p| p.id == new_parent.id}
    if new_parent.cohort >= (self.cohort || 0)
      self.cohort = new_parent.cohort + 1
      save!
    end
    Rails.logger.info("Role: Binding parent #{new_parent.name} to #{self.name}")
    parents << new_parent
  end

  def data
    current_data.data
  end

  def data=(arg)
    raise I18n.t('node_role.cannot_edit_data') unless proposed? || snapshot.proposed?
    new_data(:data, arg)
  end

  def data_update(val)
    NodeRole.transaction do
      self.data = self.data.deep_merge(val)
    end
  end

  def sysdata
    return role.sysdata(self) if role.respond_to?(:sysdata)
    current_data.sysdata
  end

  def sysdata=(arg)
    raise("#{role.name} dynamically overwrites sysdata, cannot write to it!") if role.respond_to?(:sysdata)
    new_data(:sysdata,arg)
  end

  def sysdata_update(val)
    NodeRole.transaction do
      self.sysdata = self.sysdata.deep_merge(val)
    end
  end

  def wall
    current_data.wall
  end

  def wall=(arg)
    new_data(:wall, arg)
  end

  def wall_update(val)
    NodeRole.transaction do
      self.wall = self.wall.deep_merge(val)
    end
  end

  def all_my_data
    res = {}
    res.deep_merge!(wall)
    res.deep_merge!(sysdata)
    res.deep_merge!(data)
    res
  end

  def attrib_data
    deployment_data.deep_merge(all_my_data)
  end

  def all_deployment_data
    res = {}
    all_parents.each {|parent| res.deep_merge!(parent.deployment_data)}
    res.deep_merge(deployment_data)
  end

  def all_parent_data
    res = {}
    all_parents.each do |parent|
      next unless parent.node_id == node_id || parent.role.server
      res.deep_merge!(parent.all_my_data) end
    res
  end

  def all_data
    res = all_deployment_data
    res.deep_merge!(all_parent_data)
    res.deep_merge(all_my_data)
  end

  def all_transition_data
    res = all_deployment_data
    # This will get all parent data from all the active noderoles on this node.
    res.deep_merge!(self.node.all_active_data)
    res.deep_merge!(all_parent_data)
    res.deep_merge(all_my_data)
  end

  def rerun
    NodeRole.transaction do
      raise InvalidTransition(self,state,TODO,"Cannot rerun transition") unless state == ERROR
      write_attribute("state",TODO)
      save!
    end
  end

  def deactivate
    return if proposed?
    block_or_todo
  end

  def run_hook
    # There are some limits to running hooks:
    # 1: Snapshot has to be committed.
    # 2: noderole must be available.
    # 3: role mist not be destructive, or
    #    it must have a run count of 0 (if not active),
    #    or 1 (if active)
    meth = "on_#{STATES[state]}".to_sym
    return unless snapshot.committed? &&
      available &&
      ((!role.destructive) || (run_count == self.active? ? 1 : 0))
    role.send(meth,self)
  end

  # Implement the node role state transition rules
  # by guarding state assignment.
  def state=(val)
    cstate = state
    return val if val == cstate
    Rails.logger.info("NodeRole: transitioning #{self.role.name}:#{self.node.name} from #{STATES[cstate]} to #{STATES[val]}")

    case val
    when ERROR
      # We can only go to ERROR from TRANSITION
      # but we silently ignore the transition if in BLOCKED
      return if cstate == BLOCKED
      unless (cstate == TRANSITION) || (cstate == ACTIVE)
        raise InvalidTransition.new(self,cstate,val)
      end
      write_attribute("state",val)
      save!
      run_hook
      # All children of a node_role in ERROR go to BLOCKED.
      children.each do |c|
        next unless c.snapshot.committed?
        c.state = BLOCKED
      end
    when ACTIVE
      # We can only go to ACTIVE from TRANSITION
      # but we silently ignore the transition if in BLOCKED
      return if cstate == BLOCKED
      unless cstate == TRANSITION
        raise InvalidTransition.new(self,cstate,val)
      end
      if !node.alive
        block_or_todo
        return self
      end
      write_attribute("state",val)
      save!
      run_hook
      # Immediate children of an ACTIVE node go to TODO
      children.each do |c|
        next unless c.snapshot.committed? && c.activatable?
        c.state = TODO
      end
    when TODO
      # We can only go to TODO when:
      # 1. We were in PROPOSED or BLOCKED or ERROR or ACTIVE
      # 2. All our parents are in ACTIVE
      unless ((cstate == PROPOSED) || (cstate == BLOCKED)) ||
          (cstate == ERROR) || (cstate == ACTIVE) ||
          (!node.alive && cstate == TRANSITION)
        raise InvalidTransition.new(self,cstate,val)
      end
      unless activatable?
        raise InvalidTransition.new(self,cstate,val,"Not all parents are ACTIVE")
      end
      write_attribute("state",val)
      save!
      run_hook
      # Going into TODO transitions all our children into BLOCKED.
      children.each do |c|
        c.state = BLOCKED
      end
    when TRANSITION
      # We can only go to TRANSITION from TODO
      # As an optimization, we may also want to allow a transition from
      # BLOCKED to TRANSITION directly -- the goal would be to allow a jig
      # to batch up noderole runs by noticing that a noderole it was handed
      # in TRANSITION has children on the same node utilizing the same jig
      # in BLOCKED, and preemptivly grabbing them to batch them up.
      unless (cstate == TODO) || (cstate == ACTIVE)
        raise InvalidTransition.new(self,cstate,val)
      end
      write_attribute("state",val)
      save!
      run_hook
    when BLOCKED
      # We can only go to BLOCKED from PROPOSED, TODO, or ACTIVE,
      # or if any our parents are in BLOCKED, PROPOSED, TODO or ERROR.
      unless parents.any?{|nr|nr.blocked? || nr.todo? || nr.error? || nr.proposed?} ||
          (cstate == PROPOSED || cstate == TODO) || (cstate == ACTIVE)
        raise InvalidTransition.new(self,cstate,val)
      end
      # If we are blocked, so are all our children.
      write_attribute("state",val)
      save!
      all_children.each do |c|
        c.send(:write_attribute,"state",BLOCKED)
        c.save!
      end
    when PROPOSED
      write_attribute("state",val)
      save!
      run_hook
      all_children.each do |c|
        unless c.deployment.id == self.deployment.id
          raise InvalidTransition.new(c,cstate,val,"NodeRole #{c.name} not in same deployment as #{self.name}")
        end
        c.send(:write_attribute,"state",BLOCKED)
        c.save!
      end
    else
      # No idea what this is.  Just die.
      raise InvalidState.new("Unknown state #{s.inspect}")
    end
    self
  end

  # convenience methods
  def name
   "#{deployment.name}: #{node.name}: #{role.name}" rescue I18n.t('unknown')
  end

  # Commit takes us back to TODO or BLOCKED, depending
  def commit!
    unless self.snapshot.proposed? || self.deployment.system?
      raise InvalidTransition.new(self,state,TODO,"Cannot commit! unless snapshot is in proposed!")
    end
    cstate = state
    # commit! is a no-op for ACTIVE, TRANSITION, or TODO
    return unless (cstate == PROPOSED) || (cstate == BLOCKED)
    block_or_todo
  end

  # convenience methods
  def description
    role.description
  end

  def jig
    role.jig
  end

  private

  def create_initial_datum
    NodeRoleDatum.create!(:node_role_id => id,
                          :snapshot_id => snapshot_id,
                          :current => true)
  end
  
  def block_or_todo
    NodeRole.transaction do
      if (parents.current.count == 0) || (parents.current.not_in_state(ACTIVE).count == 0)
        self.state = TODO
      else
        self.state = BLOCKED
      end
    end
  end

  def current_data
    node_role_data.active.first
  end

  def new_data(kind,val)
    NodeRoleDatum.transaction do
      nrd = current_data
      nrd = if nrd.nil?
              NodeRoleDatum.new(:node_role_id => id,
                               :snapshot_id => snapshot_id,
                               :current => true,
                               kind => val)
            else
              new_nrd = nrd.dup
              nrd.current = false
              nrd.save!
              new_nrd.node_role_id = nrd.node_role_id
              new_nrd.snapshot_id = nrd.snapshot_id
              new_nrd[kind] = val
              new_nrd
            end
      nrd.save!
    end
  end

  def run_on_todo
    return unless todo? && runnable?
    Rails.logger.info("NodeRole #{name} is runnable, kicking the annealer.")
    Run.run!
  end

end
