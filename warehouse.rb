#!/usr/bin/env ruby
require 'rubygems' rescue nil
$LOAD_PATH.unshift File.join(File.expand_path(__FILE__), "..", "..", "lib")
require_relative 'lib/chingu/traits/rotation'
require_relative 'lib/chingu/traits/direction'
require 'chingu'
require 'mqtt'
require 'digest/sha1'
include Gosu
include Chingu

# MQTT Warehouse
# --------------
# Made with love in Prague by folks at Juicymo (www.juicymo.cz)
#
# Created by Tomas Jukin (tomas.jukin@juicymo.cz)
#
#
class Warehouse < Chingu::Window
	def initialize
		super(800, 600)
		
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
		
		@forklifts = {}
		
		@messages = {}
		messages = @messages
		
		@outbox = {created: []}
		outbox = @outbox
		
		@mqtt_processor = Thread.new do
			MQTT::Client.connect('127.0.0.1') do |client|
				# From client to warehouse:
				# 	warehouse/create (send <KEY> and name as payload)
				# 	warehouse/<TOKEN>/control
				# 	warehouse/<TOKEN>/remove
				# From warehouse to client:
				# 	warehouse/created/<KEY> (will send TOKEN)
				# 	warehouse/<TOKEN>/status
				# 	warehouse/status
				# 	warehouse/settings
				client.get('warehouse/#') do |raw_topic, message|
					#puts "Process #{raw_topic}: #{message}"
					topic = raw_topic.gsub('warehouse/', '')
					messages[topic] ||= []
					messages[topic] << message
				end
			end
		end
		
		@mqtt_sender = Thread.new do
			MQTT::Client.connect('127.0.0.1') do |client|
				while true do
					outbox.each do |topic, messages|
						while message = messages.shift
							client.publish("warehouse/#{topic}", message, false)
						end
					end
					
					sleep 10
				end
			end
		end
	end
	
	ZONES = 3
	CONTAINERS = 50
	def setup
		@parallax = Chingu::Parallax.create(:x => 200, :y => 200, :rotation_center => :top_left)
		@parallax << { :image => "floor.png", :repeat_x => true, :repeat_y => true}
		
		create_shelves
		create_delivery_zones
		create_containers
		@forklifts[:default] = create_forklift 'Default'
		
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
				x = SHELF_GAP + ((SHELF_WIDTH + SHELF_GAP) * 2 * j)
				y = SHELF_GAP + ((SHELF_HEIGHT * 2 + SHELF_CORIDOR) * i)
				
				Shelf.create(:x => x, :y => y)
				Shelf.create(:x => x + SHELF_WIDTH + 1, :y => y)
				Shelf.create(:x => x, :y => y + SHELF_HEIGHT + 1)
				Shelf.create(:x => x + SHELF_WIDTH + 1, :y => y + SHELF_HEIGHT + 1)
				print '.'
			end
		end
		puts
	end
	
	def create_delivery_zones
		print 'Creating delivery zones'
		ZONES.times { DeliveryZone.create(:x => rand($window.width - (300*0.25)), :y => rand($window.height - (232*0.25))) }
		
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
		CONTAINERS.times { Container.create(:x => rand($window.width - (50*0.5)), :y => rand($window.height - (40*0.5)), :angle => rand(360)) }
		
		ok = false
		while !ok
			print '.'
			ok = true
			[Shelf, DeliveryZone, Container].each_collision([Shelf, DeliveryZone], Container) do |_, container|
				container.x = rand($window.width - (50*0.5))
				container.y = rand($window.height - (40*0.5))
				
				ok = false
				print '.'
			end
		end
		
		puts
	end
	
	def create_forklift name
		print 'Creating forklift'
		forklift = Forklift.create(:x => rand($window.width - (117*0.5)), :y => rand($window.height - (50*0.5)), :angle => rand(360))
		forklift.name = name
		
		ok = false
		while !ok
			print '.'
			ok = true
			[Shelf, Container, Forklift].each_collision([Shelf, Container], Forklift) do |_, forklift|
				forklift.x = rand($window.width - (117*0.5))
				forklift.y = rand($window.height - (50*0.5))
				
				ok = false
				print '.'
			end
		end
		
		puts
		
		forklift
	end
	
	def update
		super
		
		process_mqtt_commands
	
		game_objects.each { |go| go.color = @white }
	
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
			else
				forklift.crash!
				forklift.color = @red
			end
		end
		
		@scoreboard.text = @forklifts.map {|f| "#{f[1].name}: #{f[1].score}"}.join(', ')
		
		$window.caption = "MQTT Warehouse FPS: #{fps} Objects: #{game_objects.size}"
	end
	
	def process_mqtt_commands
		@messages.each do |name, queue|
			if queue.any?
				message = @messages[name].shift
				#puts "Use #{name}: #{message}"
				
				# name=Robot,key=<KEY>
				if name == 'create'
					data = parse_message_payload message
					topic = "created/#{data[:key]}"
					
					token = Digest::SHA1.hexdigest(data[:name] + Time.now.to_s)
					
					@forklifts[token] = create_forklift data[:name]
					
					send_mqtt_command topic, "name=#{data[:name]},token=#{token}"
				elsif name.include? '/remove'
					token = parse_token name
					
					if @forklifts[token] != nil
						@forklifts[token].destroy
						@forklifts[token] = nil
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
	
	def send_mqtt_command topic, message
		@outbox[topic] ||= []
		@outbox[topic] << message
	end
	
	def parse_message_payload message
		raw_data = message.split(',').map{|x|a = x.split('=');{a[0].to_sym => a[1]}}
		data = {}
		raw_data.each { |d| data.merge!(d) }
		
		data
	end
end

class Shelf < GameObject
	trait :bounding_box, :debug => false
	traits :collision_detection
	
	def setup
		@image = Image["shelf.png"]
		self.factor = 0.5
		
		cache_bounding_box
	end
end

class Container < GameObject
	trait :bounding_circle, :debug => true
	traits :collision_detection

	def setup
		@image = Image["container.png"]
		self.factor = 0.5

		cache_bounding_circle
	end

	def radius
		16
	end
end

class DeliveryZone < GameObject
	trait :bounding_box, :debug => false
	traits :collision_detection

	def setup
		@image = Image["stripes.png"]
		self.factor = 0.25

		cache_bounding_box
	end
end

class Forklift < GameObject
	trait :bounding_circle, :debug => true
	traits :velocity, :collision_detection, :rotation, :direction
	
	attr_accessor :name
	attr_reader :score
	
	MOVE_DAMPENING = 0.004
	TURN_DAMPENING = 0.004
	MOVE_ACCELERATION = 0.01
	TURN_ACCELERATION = 0.01
	
	MAX_MOVE_ACCELERATION = 0.5 		# -0.5 - 0.5
	MAX_ANGULAR_ACCELERATION = 1.0	# -1.0 - 1.0

	def setup
		@image = Image["forklift.png"]
		@loaded = false
		@score = 0
		@name = "Unknown"
		self.velocity_x = 0
		self.velocity_y = 0
		self.input = [:holding_left, :holding_right, :holding_down, :holding_up, :s, :r]  # NOTE: giving input an Array, not a Hash
	
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
		puts "Forklift #{self.name}: #{command}"
		commands = parse_command_data command
		
		if commands[:r] != nil
			self.angular_acceleration = [[commands[:r].to_f, -self.max_angular_acceleration].max, self.max_angular_acceleration].min
			puts "Forklift #{self.name}: Setting angular acceleration to #{self.angular_acceleration}"
		end
		
		if commands[:m] != nil
			delta = [[commands[:m].to_f, -MAX_MOVE_ACCELERATION].max, MAX_MOVE_ACCELERATION].min
			self.decrease_movement_velocity delta.abs if delta < 0
			self.increase_movement_velocity delta.abs if delta > 0
			puts "Forklift #{self.name}: Adjusting velocity by #{delta}"
		end
	end
	
	def parse_command_data command
		raw_data = command.split(',').map{|x|a = x.split('=');{a[0].to_sym => a[1]}}
		data = {}
		raw_data.each { |d| data.merge!(d) }
		
		data
	end
	
	def radius
		30
	end
	
	def crash!
		@score -= 1
	end
	
	def add_delivery!
		@score += 10
	end
	
	def load!
		@image = Image["forklift_loaded.png"]
		@loaded = true
	end
	
	def unload!
		@image = Image["forklift.png"]
		@loaded = false
	end
	
	def loaded?
		@loaded
	end
	
	def holding_left; self.turn -1; end
	def holding_right; self.turn 1; end
	def holding_down; self.decrease_movement_velocity MOVE_ACCELERATION; end
	def holding_up; self.increase_movement_velocity MOVE_ACCELERATION; end
	def s; self.movement_velocity = 0; end
	def r; self.x = $window.width / 2; self.y = $window.height / 2; end

	def update
		# dampening
		apply_dampening
	
	  # screen edge bouncing
	  if (@x < 0 || @x > $window.width) || (@y < 0 || @y > $window.height)
	  	self.x = $window.width / 2; self.y = $window.height / 2;
	  end
		#self.velocity_x = -self.velocity_x if @x < 0 || @x > $window.width
		#self.velocity_y = -self.velocity_y if @y < 0 || @y > $window.height
	end
	
	def apply_dampening
		self.velocity_x += (self.velocity_x > 0) ? -MOVE_DAMPENING : MOVE_DAMPENING if self.velocity_x != 0 && self.velocity_x.abs > MOVE_DAMPENING
		self.velocity_x = 0 if self.velocity_x.abs <= MOVE_DAMPENING
		self.velocity_y += (self.velocity_y > 0) ? -MOVE_DAMPENING : MOVE_DAMPENING if self.velocity_y != 0 && self.velocity_y.abs > MOVE_DAMPENING
		self.velocity_y = 0 if self.velocity_y.abs <= MOVE_DAMPENING
	end
end

Warehouse.new.show