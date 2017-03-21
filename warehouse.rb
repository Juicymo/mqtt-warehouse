#!/usr/bin/env ruby
require 'rubygems' rescue nil
$LOAD_PATH.unshift File.join(File.expand_path(__FILE__), "..", "..", "lib")
require_relative 'lib/core_extensions'
require_relative 'lib/chingu/traits/rotation'
require_relative 'lib/chingu/traits/direction'
require 'chingu'
require 'mqtt'
require 'digest/sha1'
require 'json'
require 'geometry'
require 'csv'
require 'smarter_csv'

include Gosu
include Chingu

MQTT_IP = '127.0.0.1'
WAREHOUSE_WIDTH = 640
WAREHOUSE_HEIGHT = 800

# MQTT Warehouse
# --------------
# Made with love in Prague by folks at Juicymo (www.juicymo.cz)
#
# Created by Tomas Jukin (tomas.jukin@juicymo.cz)
#
# @see https://github.com/Juicymo/mqtt-warehouse
class Warehouse < Chingu::Window
  def initialize
    super(WAREHOUSE_WIDTH, WAREHOUSE_HEIGHT)
    
    self.factor = 1
    
    switch_game_state(Room)
  end
end

class Room < Chingu::GameState
  def initialize(options = {})
    super(options)
    
    self.input = {:esc => :exit}

    @red = Color.new(0xFFFF0000)
    @green = Color.new(0xFF00FF00)
    @yellow = Color.new(0xFFFFFF00)
    @white = Color.new(0xFFFFFFFF)
    @black = Color.new(0xFF000000)
    
    @tokens = {}
    @forklifts = {}
    @containers = []
    @shelves = []
    @zones = []
    @long_lines = []
    @aware_lines = []
    @warning_lines = []
    @danger_lines = []
    
    load_tokens
    
    @messages = {}
    messages = @messages
    
    @outbox = {created: []}
    outbox = @outbox
    
    @mqtt_processor = Thread.new do
      MQTT::Client.connect(MQTT_IP) do |client|
        # From client to warehouse:
        #   warehouse/create (send <KEY> and name as payload)
        #   warehouse/<TOKEN>/control
        #   warehouse/<TOKEN>/remove
        # From warehouse to client:
        #   warehouse/created/<KEY> (will send TOKEN)
        #   warehouse/<TOKEN>/status
        #   warehouse/status
        #   warehouse/settings
        client.get('warehouse/#') do |raw_topic, message|
          #puts "Process #{raw_topic}: #{message}"
          topic = raw_topic.gsub('warehouse/', '')
          messages[topic] ||= []
          if messages[topic].size <= 2
            messages[topic] << message
          end
        end
      end
    end
    
    @mqtt_sender = Thread.new do
      MQTT::Client.connect(MQTT_IP) do |client|
        while true do
          outbox.each do |topic, messages|
            while message = messages.shift
              client.publish("warehouse/#{topic}", message, false)
            end
          end
          
          sleep 1
        end
      end
    end
    
    @mqtt_status_interval = 0
  end
  
  def exit
    save_tokens
    
    super
  end
  
  def load_tokens
    tokens = SmarterCSV.process('tokens.csv')
    
    tokens.each do |record|
      @tokens[record[:name]] = record[:token]
    end
  end
  
  def save_tokens
    CSV.open("tokens.csv", "w") do |csv|
      csv << ["name", "token"]
      
      @forklifts.each do |token, forklift|
        @tokens[forklift.name] = token
      end
      
      @tokens.each do |name, token|
        csv << [name, token]
      end
    end
  end
  
  ZONES = 3
  CONTAINERS = 10
  MAX_FORKLIFTS = 10
  def setup
    @parallax = Chingu::Parallax.create(:x => 199, :y => 199, :rotation_center => :top_left)
    @parallax << { :image => "floor.png", :repeat_x => true, :repeat_y => true}
    
    create_shelves
    create_delivery_zones
    create_containers
    @forklifts[:default] = create_forklift 'Default', true
    @forklifts[:default].token = :default
    
    send_mqtt_warehouse_settings
    
    @scoreboard = Chingu::Text.create("Loading...", :x => 10, :y => 10, :size => 30, :color => @black)
  end
  
  SHELF_GAP = 60
  SHELF_CORIDOR = 200
  SHELF_WIDTH = 21
  SHELF_HEIGHT = 105
  def create_shelves
    print 'Creating shelves'
    2.times do |i|
      6.times do |j|
        next if i == 0 && j == 0
        x = SHELF_GAP + ((SHELF_WIDTH + SHELF_GAP) * 2 * j)
        y = SHELF_GAP + ((SHELF_HEIGHT * 2 + SHELF_CORIDOR) * i)
        
        @shelves << Shelf.create(:x => x, :y => y)
        @shelves << Shelf.create(:x => x + SHELF_WIDTH + 1, :y => y)
        @shelves << Shelf.create(:x => x, :y => y + SHELF_HEIGHT + 1)
        @shelves << Shelf.create(:x => x + SHELF_WIDTH + 1, :y => y + SHELF_HEIGHT + 1)
        print '.'
      end
    end
    puts
  end
  
  def create_delivery_zones
    print 'Creating delivery zones'
    ZONES.times { @zones << DeliveryZone.create(:x => rand($window.width - (300*0.25)), :y => rand($window.height - (232*0.25))) }
    
    ok = false
    while !ok
      print '.'
      ok = true
      [Shelf, DeliveryZone].each_collision(Shelf, DeliveryZone) do |_, zone|
        zone.x = rand($window.width - (300*0.25))
        zone.y = rand($window.height - (232*0.25))
        
        ok = false
        print '.'
      end
    end
    puts
  end
  
  def create_containers
    print 'Creating containers'
    CONTAINERS.times { @containers << Container.create(:x => rand($window.width - (50*0.5)), :y => rand($window.height - (40*0.5)), :angle => rand(360)) }
    
    ok = false
    while !ok
      print '.'
      ok = true
      [Shelf, DeliveryZone, Container, Forklift, DefaultForklift].each_collision([Shelf, DeliveryZone, Forklift, DefaultForklift], Container) do |_, container|
        container.x = rand($window.width - (50*0.5))
        container.y = rand($window.height - (40*0.5))
        
        ok = false
        print '.'
      end
    end
    
    puts
  end
  
  def remove_forklift token
    if @forklifts[token] != nil
      forklift = @forklifts[token]
      puts "Removing forklift \"#{forklift.name}\""
      forklift.destroy
      @forklifts.delete token
    end
  end
  
  def create_forklift name, default = false
    to_be_removed = []
    @forklifts.each do |token, forklift|
      if forklift.name == name
        puts "Removing forklift \"#{forklift.name}\""
        forklift.destroy
        to_be_removed << token
      end
    end
    
    to_be_removed.each do |token|
      @forklifts.delete token
    end
  
    print "Creating forklift \"#{name}\""
    forklift = (default ? DefaultForklift : Forklift).create(:x => rand($window.width - (117*0.5)), :y => rand($window.height - (50*0.5)), :angle => rand(360))
    forklift.name = name
    
    ok = false
    while !ok
      print '.'
      ok = true
      [Shelf, Container, DefaultForklift, Forklift].each_collision([Shelf, Container, DefaultForklift], Forklift) do |_, forklift|
        forklift.x = rand($window.width - (117*0.5))
        forklift.y = rand($window.height - (50*0.5))
        
        ok = false
        print '.'
      end
      [Shelf, Container, Forklift, DefaultForklift].each_collision([Shelf, Container, Forklift], DefaultForklift) do |_, forklift|
        forklift.x = rand($window.width - (117*0.5))
        forklift.y = rand($window.height - (50*0.5))
        
        ok = false
        print '.'
      end
    end
    
    puts
    
    if default
    	forklift.sensor = Sensor.create(x: forklift.x, y: forklift.y, angle: forklift.angle)
    	forklift.long_sensor = LongSensor.create(x: forklift.x, y: forklift.y, angle: forklift.angle)
    end
    
    forklift
  end
  
  def update_autopilot
  	@long_lines = []
  	@aware_lines = []
  	@warning_lines = []
  	@danger_lines = []
  	in_danger = false
  	in_warning = false
  
  	player = @forklifts[:default]
  	if player
  	  Sensor.each_collision(Shelf) do |sensor, shelf|
  	  	line = {from: {x: sensor.x, y: sensor.y}, to: {x: shelf.x, y: shelf.y}}
	  	  segment = Geometry::Segment.new_by_arrays([line[:from][:x], line[:from][:y]], [line[:to][:x], line[:from][:y]])
	  	  
	  	  if segment.length < (sensor.radius/3)*2
					@danger_lines << line
					in_danger = true
				elsif segment.length < sensor.radius
					@warning_lines << line
					in_warning = true
				else
					@aware_lines << line
				end
	  	end
	  	Sensor.each_collision(Forklift) do |sensor, forklift|
				line = {from: {x: sensor.x, y: sensor.y}, to: {x: forklift.x, y: forklift.y}}
				segment = Geometry::Segment.new_by_arrays([line[:from][:x], line[:from][:y]], [line[:to][:x], line[:from][:y]])
							
				if segment.length < (sensor.radius/3)*2
					@danger_lines << line
					in_danger = true
				elsif segment.length < sensor.radius
					@warning_lines << line
					in_warning = true
				else
					@aware_lines << line
				end
			end
			if player.loaded?
				Sensor.each_collision(Container) do |sensor, forklift|
					line = {from: {x: sensor.x, y: sensor.y}, to: {x: forklift.x, y: forklift.y}}
					segment = Geometry::Segment.new_by_arrays([line[:from][:x], line[:from][:y]], [line[:to][:x], line[:from][:y]])
								
					if segment.length < (sensor.radius/3)*2
						@danger_lines << line
						in_danger = true
					elsif segment.length < sensor.radius
						@warning_lines << line
						in_warning = true
					else
						@aware_lines << line
					end
				end
				LongSensor.each_collision(DeliveryZone) do |sensor, forklift|
					line = {from: {x: sensor.x, y: sensor.y}, to: {x: forklift.x, y: forklift.y}}
					@long_lines << line
				end
			else
				LongSensor.each_collision(Container) do |sensor, forklift|
					line = {from: {x: sensor.x, y: sensor.y}, to: {x: forklift.x, y: forklift.y}}
					@long_lines << line
				end
			end
			
			if player.autopilot
  			if in_danger
  				player.movement_velocity = 0.0
  				player.angular_acceleration = 1.0
  				player.movement_direction = :backwards
  				player.movement_velocity = 0.5
  			elsif in_warning
  				player.angular_acceleration = 1.0
  				player.increase_movement_velocity 0.1
  			else
  				player.angular_acceleration = 0.0
  				player.increase_movement_velocity 0.5
  			end
			end
   	end
  end
  
  def update
    super
    
    process_mqtt_commands
    
    game_objects.each { |go| go.color = @white }
    
    update_autopilot
    
    Forklift.all.each do |forklift|
      if (forklift.x < 0 || forklift.x > $window.width) || (forklift.y < 0 || forklift.y > $window.height)
        remove_forklift forklift.token
      end
    end
    
    DefaultForklift.all.each do |forklift|
      if (forklift.x < 0 || forklift.x > $window.width) || (forklift.y < 0 || forklift.y > $window.height)
        forklift.x = $window.width / 2
        forklift.y = $window.height / 2
      end
    end
  
    Forklift.each_collision(DeliveryZone) do |forklift, _|
      if forklift.loaded?
        forklift.unload!
        forklift.add_delivery!
      end
      forklift.color = @green
    end
    Forklift.each_collision(Shelf) { |forklift, _| forklift.color = @red; forklift.crash!; forklift.unload! if forklift.loaded? }
    Forklift.each_collision(Forklift) do |forklift1, forklift2|
      forklift1.color, forklift2.color = @red, @red
      forklift1.crash!; forklift1.unload! if forklift1.loaded?
      forklift2.crash!; forklift2.unload! if forklift2.loaded?
    end
    Forklift.each_collision(Container) do |forklift, container|
      if !forklift.loaded?
        container.destroy
        forklift.load!
        
        create_containers if !Container.all.any?
      else
        forklift.crash!
        forklift.color = @red
      end
    end
    
    DefaultForklift.each_collision(DeliveryZone) do |forklift, _|
      if forklift.loaded?
        forklift.unload!
        forklift.add_delivery!
      end
      forklift.color = @green
    end
    DefaultForklift.each_collision(Shelf) { |forklift, _| forklift.color = @red; forklift.crash!; forklift.unload! if forklift.loaded? }
    DefaultForklift.each_collision(Forklift) do |forklift1, forklift2|
      forklift1.color, forklift2.color = @red, @red
      forklift1.crash!; forklift1.unload! if forklift1.loaded?
      forklift2.crash!; forklift2.unload! if forklift2.loaded?
    end
    DefaultForklift.each_collision(Container) do |forklift, container|
      if !forklift.loaded?
        container.destroy
        forklift.load!

        create_containers if !Container.all.any?
      else
        forklift.crash!
        forklift.color = @red
      end
    end
    
    @mqtt_status_interval += 1
    if @mqtt_status_interval >= 60
      send_mqtt_status
      send_forklifts_status
      @mqtt_status_interval = 0
    end
    
    @scoreboard.text = @forklifts.map {|f| "#{f[1].name}: #{f[1].score}"}.join("\n")
    @scoreboard.color = @black
    
    $window.caption = "MQTT Warehouse | FPS: #{fps} | Objects: #{game_objects.size}"
  end
  
  def draw
  	super
  	
  	player = @forklifts[:default]
  	if player && player.debug
    	@aware_lines.each do |line|
    		draw_line line[:from][:x], line[:from][:y], Color::GREEN, line[:to][:x], line[:to][:y], Color::GREEN, 100
    	end
    	
    	@warning_lines.each do |line|
    		draw_line line[:from][:x], line[:from][:y], Color::YELLOW, line[:to][:x], line[:to][:y], Color::YELLOW, 100
    	end
    	
    	@danger_lines.each do |line|
    		draw_line line[:from][:x], line[:from][:y], Color::RED, line[:to][:x], line[:to][:y], Color::RED, 100
    	end
    	
    	@long_lines.each do |line|
  			draw_line line[:from][:x], line[:from][:y], Color::BLUE, line[:to][:x], line[:to][:y], Color::BLUE, 100
  		end
		end
  end
  	
  
  def send_forklifts_status
    @forklifts.each do |token, forklift|
      next if !forklift.dirty
    
      payload = {status: forklift.data, time: Time.now}
      forklift.dirty = false
      
      send_mqtt_command "#{token}/status", JSON.generate(payload)
    end
  end
  
  def send_mqtt_status
    payload = {forklifts: {}, containers: [], time: Time.now}
    
    @forklifts.each do |_, forklift|
      payload[:forklifts][forklift.name] = forklift.data
    end
    
    @containers.each do |container|
      payload[:containers] << container.data
    end
  
    send_mqtt_command 'status', JSON.generate(payload)
  end
  
  def process_mqtt_commands
    @messages.each do |name, queue|
      if queue.any?
        message = @messages[name].shift
        #puts "Use #{name}: #{message}"
        
        # name=Robot,key=<KEY>
        if name == 'create'
          if @forklifts.size < MAX_FORKLIFTS
            data = parse_message_payload message
            topic = "created/#{data[:key]}"
            
            if data[:name] != nil
              token = @tokens[data[:name]] || Digest::SHA1.hexdigest(data[:name] + Time.now.to_s)
              
              @tokens[data[:name]] = token
              @forklifts[token] = create_forklift data[:name]
              @forklifts[token].token = token
              
              send_mqtt_command topic, "name=#{data[:name]},token=#{token}"
            else
              puts "Received invalid create message \"#{message}\""
            end
          else
            puts "Cannot create additional forklift \"#{data[:name]}\". Maximum forklift limit of #{MAX_FORKLIFTS} is reached."
          end
        elsif name.include? '/remove'
          token = parse_token name
          
          if @forklifts[token] != nil
            puts "Removing forklift \"#{@forklifts[token].name}\"..."
            @forklifts[token].destroy
            @forklifts.remove!(token)
          else
            puts "Warning: Trying to remove non-existing forklift #{token}"
          end
        elsif name.include? '/control'
          token = parse_token name
          
          if @forklifts[token] != nil
            @forklifts[token].control message
          else
            puts "Warning: Trying to control non-existing forklift #{token}"
          end
        end
      end
    end
  end
  
  def parse_token topic
    topic.split('/')[0]
  end
  
  def send_mqtt_warehouse_settings
    payload = {dimensions: {}, positions: {}, time: Time.now}
    
    payload[:dimensions][:arena] = {h: WAREHOUSE_HEIGHT, w: WAREHOUSE_WIDTH}
    payload[:dimensions][:forklift] = {h: 25, w: 59, r: 30}
    payload[:dimensions][:container] = {h: 20, w: 25, r: 16}
    payload[:dimensions][:zone] = {h: 58, w: 75}
    payload[:dimensions][:shelve] = {h: 105, w: 21}
    payload[:positions][:shelves] = []
    payload[:positions][:zones] = []
    
    @shelves.each do |shelf|
      payload[:positions][:shelves] << shelf.data
    end
    
    @zones.each do |zone|
      payload[:positions][:zones] << zone.data
    end
    
    MQTT::Client.connect(MQTT_IP) do |client|
      client.publish("warehouse/settings", JSON.generate(payload), true)
    end
  end
  
  def send_mqtt_command topic, message
    @outbox[topic] ||= []
    @outbox[topic] << message
  end
  
  def parse_message_payload message
    raw_data = message.gsub(/\s/, '').split(',').map{|x|a = x.split('=');{a[0].to_sym => a[1]}}
    data = {}
    raw_data.each { |d| data.merge!(d) }
    
    data
  end
end

class Shelf < GameObject
  trait :bounding_box, :debug => false
  traits :collision_detection

  attr_reader :data
  
  def setup
    @image = Image["shelf.png"]
    self.factor = 0.5
    
    cache_bounding_box
  end
  
  def data
    {x: self.x, y: self.y}
  end

  def w; 21; end
  def h; 105; end
end

class Container < GameObject
  trait :bounding_circle, :debug => true
  traits :collision_detection
  
  attr_reader :data

  def setup
    @image = Image["container.png"]
    self.factor = 0.5

    cache_bounding_circle
  end
  
  def data
    {x: x, y: y}
  end

  def w; 32; end
  def h; 32; end

  def radius
    16
  end
end

class DeliveryZone < GameObject
  trait :bounding_box, :debug => false
  traits :collision_detection

  attr_reader :data
  
  def setup
    @image = Image["stripes.png"]
    self.factor = 0.25

    cache_bounding_box
  end
  
  def data
    {x: x, y: y}
  end
  
  def w; 75; end
  def h; 58; end
end

MOVE_DAMPENING = 0.004
TURN_DAMPENING = 0.004
MOVE_ACCELERATION = 0.01
TURN_ACCELERATION = 0.01

MAX_MOVE_ACCELERATION     = 0.50001   # -0.5 - 0.5
MAX_ANGULAR_ACCELERATION   = 1.00001    # -1.0 - 1.0

class Forklift < GameObject
  trait :bounding_circle, :debug => true
  traits :velocity, :collision_detection, :rotation, :direction
  
  attr_accessor :name, :dirty, :token
  attr_reader :score, :data
  
  def setup
    @image = Image["forklift.png"]
    @loaded = false
    @score = 0
    @name = "Unknown"
    @dirty = true
    self.velocity_x = 0
    self.velocity_y = 0
    #self.movement_direction = :backwards
    #self.angular_acceleration = 0.4
    self.max_angular_acceleration = MAX_ANGULAR_ACCELERATION
    #self.movement_acceleration = 0.1
    #self.max_movement_acceleration = 0.1
    #self.movement_velocity = 0.1
    #self.set_acceleration_in_angle -45, 0.1

    self.factor = 0.5
    self.rotation_center = :center
    
    cache_bounding_circle
  end
  
  def control command
    # r=0.5,m=0.5
    puts "Forklift #{self.name}: Received command \"#{command}\""
    commands = parse_command_data command
    
    if commands[:r] != nil
      @dirty = true
      self.angular_acceleration = [[commands[:r].to_f, -self.max_angular_acceleration].max, self.max_angular_acceleration].min
      puts "Forklift #{self.name}: Setting angular acceleration to #{self.angular_acceleration}"
    end
    
    if commands[:m] != nil
      @dirty = true
      delta = [[commands[:m].to_f, -MAX_MOVE_ACCELERATION].max, MAX_MOVE_ACCELERATION].min
      self.decrease_movement_velocity delta.abs if delta < 0
      self.increase_movement_velocity delta.abs if delta > 0
      puts "Forklift #{self.name}: Adjusting velocity by #{delta}"
    end
  end
   
  def data
    {name: self.name, x: self.x, y: self.y, angle: self.angle, score: self.score, loaded: loaded?}
  end
  
  def w; 59; end
  def h; 25; end
  
  def parse_command_data command
    raw_data = command.split(',').map{|x|a = x.split('=');{a[0].to_sym => a[1]}}
    data = {}
    raw_data.each { |d| data.merge!(d) }
    
    data
  end
  
  def radius
    30
  end
  
  def delimeter
  	radius * 2
  end
  
  def crash!
    @dirty = true
    @score -= 1
  end
  
  def add_delivery!
    @dirty = true
    @score += 10
  end
  
  def load!
    @dirty = true
    @image = Image["forklift_loaded.png"]
    @loaded = true
  end
  
  def unload!
    @dirty = true
    @image = Image["forklift.png"]
    @loaded = false
  end
  
  def loaded?
    @loaded
  end
  
  def update
    # dampening
    apply_dampening
  
    # screen edge bouncing
    #self.velocity_x = -self.velocity_x if @x < 0 || @x > $window.width
    #self.velocity_y = -self.velocity_y if @y < 0 || @y > $window.height
  end
  
  def apply_dampening
    self.velocity_x += (self.velocity_x > 0) ? -MOVE_DAMPENING : MOVE_DAMPENING if self.velocity_x != 0 && self.velocity_x.abs > MOVE_DAMPENING
    self.velocity_x = 0 if self.velocity_x.abs <= MOVE_DAMPENING
    self.velocity_y += (self.velocity_y > 0) ? -MOVE_DAMPENING : MOVE_DAMPENING if self.velocity_y != 0 && self.velocity_y.abs > MOVE_DAMPENING
    self.velocity_y = 0 if self.velocity_y.abs <= MOVE_DAMPENING
  end
  
  def self.inside_viewport
    all.select { |forklift| forklift.game_state.viewport.inside?(forklift) }
  end
end

class Sensor < GameObject
  trait :bounding_circle, :debug => false
  traits :collision_detection

	def setup
		@image = Image["alpha.png"]
		self.rotation_center = :center

		cache_bounding_circle
	end

	def radius
		SENSOR_RANGE
	end
end

class LongSensor < Sensor
	def radius
		LONG_SENSOR_RANGE
	end
end

SENSOR_RANGE = 60
LONG_SENSOR_RANGE = 120
class DefaultForklift < Forklift
  attr_accessor :sensor, :long_sensor
  attr_reader :autopilot, :debug

  def setup
    super
  
    @autopilot = false
    @debug = false
    self.input = [:holding_left, :holding_right, :holding_down, :holding_up, :s, :r, :a, :d]  # NOTE: giving input an Array, not a Hash
  end
  
  def update
  	super
  	
  	if self.sensor
	  	self.sensor.x = self.x
	  	self.sensor.y = self.y
	  	self.sensor.angle = self.angle
  	end
  	
  	if self.long_sensor
		  self.long_sensor.x = self.x
		  self.long_sensor.y = self.y
		  self.long_sensor.angle = self.angle
		end
  end
  
  # state_machine :state, initial: :parked do
  # end

  def holding_left; self.turn -1; end
  def holding_right; self.turn 1; end
  def holding_down; self.decrease_movement_velocity MOVE_ACCELERATION; end
  def holding_up; self.increase_movement_velocity MOVE_ACCELERATION; end
  def s; self.movement_velocity = 0; end
  def r; self.x = $window.width / 2; self.y = $window.height / 2; end
  def d; @debug = !@debug; end
  def a
    @autopilot = !@autopilot
    self.angular_acceleration = 0.0 if !@autopilot
  end
  
end

Warehouse.new.show