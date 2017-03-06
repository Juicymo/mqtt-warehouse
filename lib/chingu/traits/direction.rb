#--
#
# Chingu -- OpenGL accelerated 2D game framework for Ruby
# Copyright (C) 2009 ippa / ippa@rubylicio.us
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
#++

X = 0
Y = 1

module Chingu
	module Traits
		#
		# A chingu trait providing direction movement logic.
		# Requires velocity and rotation traits
		#
		module Direction
			attr_accessor :movement_acceleration, :max_movement_acceleration, :movement_velocity, :max_movement_velocity, :movement_direction

			module ClassMethods
				def initialize_trait(options = {})
					trait_options[:direction] = {:apply => true}.merge(options)
				end
			end

			def setup_trait(options)
				@direction_options = {:debug => false}.merge(options)
				
				@movement_acceleration = options[:movement_acceleration] || 0
				@reverse_movement_acceleration = options[:reverse_movement_acceleration] || 0
				@max_movement_acceleration = options[:max_movement_acceleration] || 1
				
				@movement_velocity = options[:movement_velocity] || 0
				@movement_direction = options[:movement_direction] || (movement_velocity >= 0 ? :forward : :backward)
				@max_movement_velocity = options[:max_movement_velocity] || 1

				@acceleration_angle = options[:acceleration_angle] || 0
				@movement_acceleration_in_angle = options[:movement_acceleration_in_angle] || 0
				super
			end

			def update_trait
				#
				# if option :apply is false, don't apply movement_acceleration to acceleration_x and acceleration_y
				#
				if (trait_options[:direction][:apply] == true)
					update_velocity_vector
				
					accelerate_in_angle self.angle, @movement_acceleration if @movement_acceleration != 0
					accelerate_in_angle self.angle + 180, @reverse_movement_acceleration if @reverse_movement_acceleration != 0
					
					if @movement_acceleration_in_angle != 0
						radians = self.deg_to_rad(@acceleration_angle)
						@acceleration_x += Math.cos(radians) * @movement_acceleration_in_angle
						@acceleration_y += Math.sin(radians) * @movement_acceleration_in_angle
					end
				end

				super
			end
			
			def accelerate_in_angle degrees, speed
				radians = self.deg_to_rad(degrees)
				self.acceleration_x = Math.cos(radians) * speed
				self.acceleration_y = Math.sin(radians) * speed
			end
			
			def nudge_in_angle degrees, speed
				radians = self.deg_to_rad(degrees)
				self.velocity_x += Math.cos(radians) * speed
				self.velocity_y += Math.sin(radians) * speed
			end
			
			def turn angle_delta
				self.angle += angle_delta
				update_velocity_vector
			end
			
			def movement_velocity
				Math.sqrt((@velocity_x || 0)**2 + (@velocity_y || 0)**2)
			end
			
			def increase_movement_velocity delta
				self.reverse_movement_direction if moving_backward? && self.movement_velocity - delta < delta && self.movement_velocity + delta > 0
				
				if moving_forward?
					self.movement_velocity += delta
				else
					self.movement_velocity -= delta
				end
			end
			
			def decrease_movement_velocity delta
				self.reverse_movement_direction if moving_forward? && self.movement_velocity - delta < 0
				
				if moving_forward?
					self.movement_velocity -= delta
				else
					self.movement_velocity += delta
				end
			end
			
			def reverse_movement_direction
				self.movement_direction = moving_forward? ? :backward : :forward
			end
			
			def moving_forward?
				self.movement_direction == :forward
			end
			
			def moving_backward?
				!moving_forward?
			end
			
			def update_velocity_vector
				self.movement_velocity = self.movement_velocity
			end
			
			#
			# Modifies velocity_x and velocity_y of parent according to movement_velocity and angle
			#
			def movement_velocity=(new_velocity)
				is_accelerating = new_velocity > @movement_velocity
				is_decelerating = new_velocity <= @movement_velocity
				is_too_fast = @movement_velocity > @max_movement_velocity
				is_too_slow = @movement_velocity < -@max_movement_velocity
				
				if (is_accelerating && !is_too_fast) || (is_decelerating && !is_too_slow) ||
					 (is_decelerating && is_too_fast) || (is_accelerating && is_too_slow)
					@movement_velocity = new_velocity
				end
				
				radians = self.deg_to_rad(self.angle + (@movement_direction == :forward ? 0 : 180))
				self.velocity_x = (Math.cos(radians) * @movement_velocity)
				self.velocity_y = (Math.sin(radians) * @movement_velocity)
			end
			
			#
			# Setts movement_velocity to 0, stopping the game object
			# Note it doesn't reset the acceleration!
			#
			def reset_movement_velocity
				self.movement_velocity = 0
			end
			
			def movement_acceleration
				@movement_acceleration = Math.sqrt(@acceleration_x**2 + @acceleration_y**2)
			end
			
			#
			# Modifies acceleration_x and acceleration_y of parent according to movement_acceleration and angle
			#
			def movement_acceleration=(val)
				@movement_acceleration = val if (@movement_acceleration).abs < @max_movement_acceleration
			end
			
			def reverse_movement_acceleration
				@reverse_movement_acceleration = Math.sqrt(@acceleration_x**2 + @acceleration_y**2)
			end
			
			#
			# Modifies acceleration_x and acceleration_y of parent according to movement_acceleration and angle
			#
			def reverse_movement_acceleration=(val)
				@reverse_movement_acceleration = val if (@reverse_movement_acceleration).abs < @max_movement_acceleration
			end

			#
			# Setts movement_acceleration to 0, stopping the game object
			# Note it doesn't reset the acceleration!
			#
			def reset_movement_acceleration
				self.movement_acceleration = 0
				self.reverse_movement_acceleration = 0
			end
			
			#
			# Setts movement_acceleration to 0, stopping the game object
			# Note it doesn't reset the acceleration!
			#
			def remove_movement_acceleration
				self.movement_acceleration = 0
				accelerate_in_angle 0, 0
			end
			
			def set_acceleration_in_angle degrees, speed
				@acceleration_angle = degrees
				@movement_acceleration_in_angle = speed
			end
			
			def unset_acceleration_in_angle
				@acceleration_angle = 0
				@movement_acceleration_in_angle = 0
			end
			
			def vector_add a, b
				[a[X] + b[X], a[Y] + b[Y]]
			end
			
			def vector_sub a, b
				[a[X] - b[X], a[Y] - b[Y]]
			end
			
			def vector_mul a, c
				[a[X] * c, a[Y] * c]
			end
			
			def vector_dot a, b
				(a[X] * b[X]) + (a[Y] * b[Y])
			end
		end
	end
end