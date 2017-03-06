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

module Chingu
	module Traits
		#
		# A chingu trait providing angular acceleration logic.
		# Adds parameters: angular_acceleration, max_angular_acceleration and modifies self.angle
		# Also keeps previous_angle which is the angle before modification.
		# Can be useful for example collision detection
		#
		module Rotation
			attr_accessor :angular_acceleration, :max_angular_acceleration
			attr_reader :previous_angle

			module ClassMethods
				def initialize_trait(options = {})
					trait_options[:rotation] = {:apply => true}.merge(options)
				end
			end

			def setup_trait(options)
				@rotation_options = {:debug => false}.merge(options)

				@angular_acceleration = options[:angular_acceleration] || 0
				
				@max_angular_acceleration = options[:max_angular_acceleration] || 10
				
				super
			end

			#
			# Modifies angle of parent
			#
			def update_trait
				@previous_angle = self.angle

				#
				# if option :apply is false, don't apply angular_acceleration to angle
				#
				self.angle += @angular_acceleration if (trait_options[:rotation][:apply] == true) && (@angular_acceleration).abs < @max_angular_acceleration

				super
			end

			#
			# Setts velocity_x and velocity_y to 0, stopping the game object
			# Note it doesn't reset the acceleration!
			#
			def reset_angular_acceleration
				@angular_acceleration = 0
			end

			#
			# Returns true if angular_acceleration is 0
			#
			def angular_stopped?
				@angular_acceleration == 0
			end

			#
			# Did game object changed angle last tick
			#
			def angular_moved?
				self.angle != @previous_angle
			end
			
			def angle_deg
				self.angle
			end
			
			def angle_rad
				deg_to_rad angle_deg
			end
			
			def deg_to_rad degrees
				degrees * Math::PI / 180
			end
		end
	end
end