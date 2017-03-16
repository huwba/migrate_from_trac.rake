# Redmine - project management software
# Copyright (C) 2006-2014  Jean-Philippe Lang
# Copyright (C) 2007-2011  Trac/Redmine Community
# References:
#  - http://www.redmine.org/boards/1/topics/12273 (Trac Importer Patch Coordination)
#  - http://github.com/landy2005/Redmine-migrate-from-Trac
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'active_record'
require 'iconv' if RUBY_VERSION < '1.9'
require 'pp'
require 'digest/sha1'

namespace :redmine do
  desc 'Trac migration script'
  #task :migrate_from_trac => :environment do
  multitask :migrate_from_trac => :environment do
    
    module TracMigrate
        TICKET_MAP = []

        DEFAULT_STATUS = IssueStatus.find_by_name('Open')
        assigned_status = IssueStatus.find_by_name('In Progress')
        feedback_status = IssueStatus.find_by_name('Feedback')
        closed_status = IssueStatus.where(:is_closed => true).first
        STATUS_MAPPING = {'new' => DEFAULT_STATUS,
                          'reopened' => feedback_status,
                          'assigned' => assigned_status,
                          'closed' => closed_status,
                          'tested' => tested_status,
                          'documented' => documented_status,
                          'implemented' => impmented_status
                          }

                          
                          
                          
                          
        priorities = IssuePriority.all
        DEFAULT_PRIORITY = priorities[0]
        PRIORITY_MAPPING = {'lowest' => priorities[0],
                            'low' => priorities[0],
                            'normal' => priorities[1],
                            'high' => priorities[2],
                            'highest' => priorities[3],
                            # ---
                            'trivial' => priorities[0],
                            'minor' => priorities[0],
                            'major' => priorities[1],
                            'critical' => priorities[2],
                            'blocker' => priorities[3]
                            }

        TRACKER_BUG = Tracker.find_by_name('Defect')
        TRACKER_FEATURE = Tracker.find_by_name('Feature')
        TRACKER_SUPPORT = Tracker.find_by_name('Support')
        TRACKER_TASK = Tracker.find_by_name('Task')
        TRACKER_CONFIG = Tracker.find_by_name('Configuration')
        DEFAULT_TRACKER = TRACKER_BUG
        TRACKER_MAPPING = {'defect' => TRACKER_BUG,
                           'enhancement' => TRACKER_FEATURE,
                           'task' => TRACKER_TASK,
                           'business task' => TRACKER_SUPPORT,
                           'configuration' => TRACKER_CONFIG
                           }

        roles = Role.where(:builtin => 0).order('position ASC').all
        manager_role = roles[0]
        developer_role = roles[1]
        DEFAULT_ROLE = roles.last
        ROLE_MAPPING = {'admin' => manager_role,
                        'developer' => developer_role
                        }
        # Add an Hash Table for comments' updatable fields
        PROP_MAPPING = {'status' => 'status_id',
                        'owner' => 'assigned_to_id',
                        'component' => 'category_id',
                        'milestone' => 'fixed_version_id',
                        'priority' => 'priority_id',
                        'summary' => 'subject',
                        'type' => 'tracker_id'}
        
        # Hash table to map completion ratio
        RATIO_MAPPING = {'' => 0,
                        'fixed' => 100,
                        'invalid' => 0,
                        'wontfix' => 0,
                        'duplicate' => 0,
                        'worksforme' => 0}

      class ::Time
        class << self
          def at2(time)
            # In Trac ticket #6466, timestamps
            # were changed from seconds since the epoch
            # to microseconds since the epoch.  The
            # Trac database version was bumped to 23 for this.
            if TracMigrate.database_version > 22
               Time.at(time / 1000000)
            else
               Time.at(time)
            end
          end
        end
      end

      class TracSystem < ActiveRecord::Base
        self.table_name = :system
      end

      class TracComponent < ActiveRecord::Base
        self.table_name = :component
      end

      class TracMilestone < ActiveRecord::Base
        self.table_name = :milestone
        # If this attribute is set a milestone has a defined target timepoint
        def due
          if read_attribute(:due) && read_attribute(:due) > 0
            Time.at2(read_attribute(:due)).to_date
          else
            nil
          end
        end
        # This is the real timepoint at which the milestone has finished.
        def completed
          if read_attribute(:completed) && read_attribute(:completed) > 0
            Time.at2(read_attribute(:completed)).to_date
          else
            nil
          end
        end

        def description
          # Attribute is named descr in Trac v0.8.x
          has_attribute?(:descr) ? read_attribute(:descr) : read_attribute(:description)
        end
      end

      class TracTicketCustom < ActiveRecord::Base
        self.table_name = :ticket_custom

        def value
          read_attribute(:value)
        end
      end

      class TracAttachment < ActiveRecord::Base
        self.table_name = :attachment
       self.inheritance_column = :none

        self.primary_key = :id
        # NOTE: not correct as this should be composed, but this prevents
        # failing import of attachments as the id is otherwise not correct or a
        # ActiveRecord::UnknownPrimaryKey will occure

        def time
          Time.at2(read_attribute(:time))
        end

        def original_filename
          filename
        end

        def content_type
          ''
        end

        def exist?
          File.file? trac_fullpath
        end

        def open
          File.open("#{trac_fullpath}", 'rb') {|f|
            @file = f
            yield self
          }
        end

        def read(*args)
          @file.read(*args)
        end

        def description
          read_attribute(:description).to_s.slice(0,255)
        end

        def trac_fullpath
          attachment_type = read_attribute(:type)
          ticket_id = read_attribute(:id)
          filename = read_attribute(:filename)

          path = get_path_1_0(ticket_id, filename)
          full_path_1_0 = "#{TracMigrate.trac_attachments_directory}/#{attachment_type}/#{path}"
          return full_path_1_0 if File.file? full_path_1_0

          path = get_path_pre_1_0(ticket_id, filename)
          full_path_pre_1_0 = "#{TracMigrate.trac_attachments_directory}/#{attachment_type}/#{path}"
          return full_path_pre_1_0 if File.file? full_path_pre_1_0

          path = get_path_pre_0_11(ticket_id, filename)
          full_path_pre_0_11 = "#{TracMigrate.trac_attachments_directory}/#{attachment_type}/#{path}"
          return full_path_pre_0_11 if File.file? full_path_pre_0_11

          return full_path_pre_1_0 # needed for logging 

        end

      private

        def sha1(s)
            return Digest::SHA1.hexdigest(s)
        end

        def get_path_1_0(ticket_id, filename)

          # suitable for most recent versions of trac:
            t = sha1(ticket_id.to_s)
            f = sha1(filename)
            ext = File.extname(filename)
            a = [ t[0..2], "/", t, "/", f, ext ]
            return a.join("")
        end

        def get_path_pre_1_0(ticket_id, filename)

          # older versions of trac (pre 1.0?)
          t = ticket_id.to_s
          f = URI::encode(filename, Regexp.new("[^a-zA-Z0-9\._\-]"))
          a = [t, "/", f]

          return a.join("")
        end

        def get_path_pre_0_11(ticket_id, filename)

          # older versions of trac (pre 0.11?)
          t = ticket_id.to_s
          f = filename
          a = [t, "/", f]

          return a.join("")
        end
      end

      class TracTicket < ActiveRecord::Base
        self.table_name = :ticket
       self.inheritance_column = :none

        # ticket changes: only migrate status changes and comments
        has_many :ticket_changes, :class_name => "TracTicketChange", :foreign_key => :ticket
        has_many :customs, :class_name => "TracTicketCustom", :foreign_key => :ticket

        def attachments
          TracMigrate::TracAttachment.where(:type => 'ticket', :id => self.id.to_s)
        end 

        def ticket_type
          read_attribute(:type)
        end

        def summary
          read_attribute(:summary).blank? ? "(no subject)" : read_attribute(:summary)
        end

        def description
          read_attribute(:description).blank? ? summary : read_attribute(:description)
        end

        def time
            Time.at2(read_attribute(:time))
        end

        def changetime
            Time.at2(read_attribute(:changetime))
        end
      end

      class TracTicketChange < ActiveRecord::Base
        self.table_name = :ticket_change

        def self.columns
          # Hides Trac field 'field' to prevent clash with AR field_changed? method (Rails 3.0)
          super.select {|column| column.name.to_s != 'field'}
        end

        def time
            Time.at2(read_attribute(:time))
        end
      end

      TRAC_WIKI_PAGES = %w(InterMapTxt InterTrac InterWiki RecentChanges SandBox TracAccessibility TracAdmin TracBackup \
                           TracBrowser TracCgi TracChangeset TracInstallPlatforms TracMultipleProjects TracModWSGI \
                           TracEnvironment TracFastCgi TracGuide TracImport TracIni TracInstall TracInterfaceCustomization \
                           TracLinks TracLogging TracModPython TracNotification TracPermissions TracPlugins TracQuery \
                           TracReports TracRevisionLog TracRoadmap TracRss TracSearch TracStandalone TracSupport TracSyntaxColoring TracTickets \
                           TracTicketsCustomFields TracTimeline TracUnicode TracUpgrade TracWiki WikiDeletePage WikiFormatting \
                           WikiHtml WikiMacros WikiNewPage WikiPageNames WikiProcessors WikiRestructuredText WikiRestructuredTextLinks \
                           CamelCase TitleIndex TracNavigation TracFineGrainedPermissions TracWorkflow TimingAndEstimationPluginUserManual \
                           PageTemplates BadContent)
      class TracWikiPage < ActiveRecord::Base
        self.table_name = :wiki
        self.primary_key = :name

        def self.columns
          # Hides readonly Trac field to prevent clash with AR readonly? method (Rails 2.0)
          super.select {|column| column.name.to_s != 'readonly'}
        end
 
        def attachments
          TracMigrate::TracAttachment.where(:type => 'wiki', :id => self.id.to_s)
        end 

        def time
          Time.at2(read_attribute(:time))
        end
      end

      class TracPermission < ActiveRecord::Base
        self.table_name = :permission
      end

      class TracSessionAttribute < ActiveRecord::Base
        self.table_name = :session_attribute
      end

# TODO put your Login Mapping in this method and rename method below
#      def self.find_or_create_user(username, project_member = false)
#        TRAC_REDMINE_LOGIN_MAP = []
#        return TRAC_REDMINE_LOGIN_MAP[username]
# OR more hard-coded:
#        if username == 'TracX'
#          username = 'RedmineX'
#        elsif username == 'gilles'
#          username = 'gcornu'
#        #elseif ...
#        else
#          username = 'gcornu'
#        end
#        return User.find_by_login(username)  
#      end

      def self.find_or_create_user(username, project_member = false)
        return User.anonymous if username.blank?

        u = User.find_by_login(username)
        if !u
          # Create a new user if not found
          mail = username[0, User::MAIL_LENGTH_LIMIT]
          if mail_attr = TracSessionAttribute.find_by_sid_and_name(username, 'email')
            mail = mail_attr.value
          end
          mail = "#{mail}@foo.bar" unless mail.include?("@")

          name = username
          if name_attr = TracSessionAttribute.find_by_sid_and_name(username, 'name')
            name = name_attr.value
          end
          name =~ (/(.+?)(?:[\ \t]+(.+)?|[\ \t]+|)$/)
          fn = $1.strip
          # Add a dash for lastname or the user is not saved (bugfix)
          ln = ($2 || '-').strip

          u = User.new :mail => mail.gsub(/[^-@a-z0-9\.]/i, '-'),
                       :firstname => fn[0, limit_for(User, 'firstname')],
                       :lastname => ln[0, limit_for(User, 'lastname')]

          u.login = username[0, User::LOGIN_LENGTH_LIMIT].gsub(/[^a-z0-9_\-@\.]/i, '-')
          u.password = 'trac'
          u.admin = true if TracPermission.find_by_username_and_action(username, 'admin')
          # finally, a default user is used if the new user is not valid
          u = User.first unless u.save
        end
        # Make sure user is a member of the project
        if project_member && !u.member_of?(@target_project)
          role = DEFAULT_ROLE
          if u.admin
            role = ROLE_MAPPING['admin']
          elsif TracPermission.find_by_username_and_action(username, 'developer')
            role = ROLE_MAPPING['developer']
          end
          Member.create(:user => u, :project => @target_project, :roles => [role])
          u.reload
        end
        u
      end

      # Basic wiki syntax conversion
      def self.convert_wiki_text(text)
        convert_wiki_text_mapping(text, TICKET_MAP)
      end

      def self.migrate
        establish_connection

        # Quick database test
        TracComponent.count
        lookup_database_version
        print "Trac database version is: ", database_version, "\n" 
        custom_field_map = {}
        migrated_components = 0
        migrated_milestones = 0
        migrated_tickets = 0
        migrated_custom_values = 0
        migrated_ticket_attachments = 0
        migrated_wiki_edits = 0
        migrated_wiki_attachments = 0
        save_errors_wiki_attachments = 0
        save_errors_ticket_attachments = 0

        # Wiki system initializing...
        @target_project.wiki.destroy if @target_project.wiki
        @target_project.reload
        wiki = Wiki.new(:project => @target_project, :start_page => 'WikiStart')
        wiki_edit_count = 0

        # Components
        who = "Migrating components"
        issues_category_map = {}
        components_total = TracComponent.count
        TracComponent.all.each do |component|
          c = IssueCategory.new :project => @target_project,
                                :name => encode(component.name[0, limit_for(IssueCategory, 'name')])
        # Owner
        unless component.owner.blank?
          c.assigned_to = find_or_create_user(component.owner, true)
        end
        next unless c.save
        issues_category_map[component.name] = c
        migrated_components += 1
        simplebar(who, migrated_components, components_total)
        end
        puts if migrated_components < components_total

        # Milestones
        who = "Migrating milestones"
        version_map = {}
        milestones_closed = Array.new
        milestone_wiki = Array.new
        milestones_total = TracMilestone.count
        TracMilestone.all.each do |milestone|
          # First we try to find the wiki page...
          p = wiki.find_or_new_page(milestone.name.to_s)
          p.content = WikiContent.new(:page => p) if p.new_record?
          p.content.text = milestone.description.to_s
          p.content.author = find_or_create_user('trac')
          p.content.comments = 'Milestone'
          p.save

          v = Version.new :project => @target_project,
                          :name => encode(milestone.name),
                          :description => nil,
                          :wiki_page_title => milestone.name.to_s,
                          :effective_date => (!milestone.completed.blank? ? milestone.completed : (!milestone.due.blank? ? milestone.due : nil))

          next unless v.save
          version_map[milestone.name] = v
          milestones_closed.push(v.id) if !milestone.completed.blank?
          milestone_wiki.push(milestone.name);
          migrated_milestones += 1
          simplebar(who, migrated_milestones, milestones_total)
        end
        puts if migrated_milestones < milestones_total

        # Custom fields
        # TODO: read trac.ini instead
        #print "Migrating custom fields"
        custom_field_map = {}
        TracTicketCustom.find_by_sql("SELECT DISTINCT name FROM #{TracTicketCustom.table_name}").each do |field|
# use line below and adapt the WHERE condifiton, if you want to skip some unused custom fields
#        TracTicketCustom.find_by_sql("SELECT DISTINCT name FROM #{TracTicketCustom.table_name} WHERE name NOT IN ('duration', 'software')").each do |field|
          #print '.' # Maybe not needed this out?
          #STDOUT.flush
          # Redmine custom field name
          field_name = encode(field.name[0, limit_for(IssueCustomField, 'name')]).humanize

#          # Ugly hack to skip custom field 'Browser', which is in 'list' format...
#          next if field_name == 'browser'

          # Find if the custom already exists in Redmine
          f = IssueCustomField.find_by_name(field_name)
          # Ugly hack to handle billable checkbox. Would require to read the ini file to be cleaner
          if field_name == 'Billable'
            format = 'bool'
          else
            format = 'string'
          end
          
          possible_vals = ' '
          
          
          # Or create a new one
          f ||= IssueCustomField.create(:name => field_name,
                                        :field_format => format, :possible_values => possible_vals)

          next if f.new_record?
          f.trackers = Tracker.all
          f.projects << @target_project
          custom_field_map[field.name] = f
        end
        #puts

#        # Trac custom field 'Browser' field as a Redmine custom field
#        b = IssueCustomField.find(:first, :conditions => { :name => "Browser" })
#        b = IssueCustomField.new(:name => 'Browser',
#                                 :field_format => 'list',
#                                 :is_filter => true) if b.nil?
#        b.trackers << [TRACKER_BUG, TRACKER_FEATURE, TRACKER_SUPPORT]
#        b.projects << @target_project
#        b.possible_values = (b.possible_values + %w(IE6 IE7 IE8 IE9 Firefox Chrome Safari Opera)).flatten.compact.uniq
#        b.save!
#        custom_field_map['browser'] = b

        # Trac 'resolution' field as a Redmine custom field
        r = IssueCustomField.where(:name => "Resolution").first
        r = IssueCustomField.new(:name => 'Resolution',
                                 :field_format => 'list',
                                 :is_filter => true) if r.nil?
        r.trackers << Tracker.all
        r.projects << @target_project
        r.possible_values = (r.possible_values + %w(fixed invalid wontfix duplicate worksforme)).flatten.compact.uniq
        r.save!
        custom_field_map['resolution'] = r
       
	 # Trac 'keywords' field as a Redmine custom field
      #  k = IssueCustomField.where(:name => "Keywords").first 
        k = IssueCustomField.new(:name => 'Keywords',
                                 :field_format => 'string',
                                 :is_filter => true) if k.nil?
        k.trackers << Tracker.all
        k.projects << @target_project
        k.save!
        custom_field_map['keywords'] = k

            # Trac 'version' field as a Redmine custom field, taking advantage of feature #2096 (available since Redmine 1.2.0)
      #  v = IssueCustomField.find(:first, :conditions => { :name => "Found in Version" })
      #  v = IssueCustomField.new(:name => 'Found in Version',
      #                           :field_format => 'version',
      #                           :is_filter => true) if v.nil?
        # Only apply to BUG tracker (?)
     #   v.trackers << TRACKER_BUG
        #v.trackers << [TRACKER_BUG, TRACKER_FEATURE]

        # Affect custom field to current Project
    #    v.projects << @target_project

    #    v.save!
    #    custom_field_map['found_in_version'] = v

        # Trac ticket id as a Redmine custom field
        #tid = IssueCustomField.find(:first, :conditions => { :name => "TracID" })
        tid = IssueCustomField.new(:name => 'TracID',
                                   :field_format => 'string',
                                   :is_filter => true) if tid.nil?
        tid.trackers << Tracker.all
        tid.projects << @target_project
        tid.save!
        custom_field_map['tracid'] = tid
  
        # Tickets
         skipTickets = false # ticket migration can be turned off for debugging purposes
        if !skipTickets 
          parent_issue_map = Hash.new
        who = "Migrating tickets"
           tickets_total = TracTicket.count
           TracTicket.find_each(:batch_size => 200) do |ticket|
          i = Issue.new :project => @target_project,
                          :subject => encode(ticket.summary),
                          :description => encode(ticket.description),
                          :priority => PRIORITY_MAPPING[ticket.priority] || DEFAULT_PRIORITY,
                          :created_on => ticket.time
          # Add the ticket's author to project's reporter list (bugfix)
          i.author = find_or_create_user(ticket.reporter,true)
          # Extrapolate done_ratio from ticket's resolution
          i.done_ratio = RATIO_MAPPING[ticket.resolution] || 0 
          i.category = issues_category_map[ticket.component] unless ticket.component.blank?
          i.fixed_version = version_map[ticket.milestone] unless ticket.milestone.blank?
          i.status = STATUS_MAPPING[ticket.status] || DEFAULT_STATUS
          i.tracker = TRACKER_MAPPING[ticket.ticket_type] || DEFAULT_TRACKER
          # Use the Redmine-genereated new ticket ID anyway (no Ticket ID recycling)
          i.id = ticket.id unless Issue.exists?(ticket.id)
          next unless i.save
    	    unless i.save 
		i.errors.full_messages.each do |msg|
			print "\nERROR : ",msg,"\n"
		     end
		     print "ERROR: Error saving issue.\n"
	             next
	    end           

 
            # set timestamps with validation off (validation seems to fore all timestamps to be at NOW)
            i.update_attribute(:created_on, ticket.time)
            i.update_column(:updated_on, ticket.changetime)
            last_updated_on = ticket.changetime
          TICKET_MAP[ticket.id] = i.id
          migrated_tickets += 1
          simplebar(who, migrated_tickets, tickets_total)
          # Owner
            unless ticket.owner.blank?
              i.assigned_to = find_or_create_user(ticket.owner, true)
              i.save
            end
          # Handle CC field
          # Feature disabled (CC field almost never used, No time to validate/test this recent improvments from A. Callegaro)
            if !ticket.cc.nil?
	    ticket.cc.try(:split,',').each do |email|
            w = Watcher.new :watchable_type => 'Issue',
                            :watchable_id => i.id,
                            :user_id => find_or_create_user(email.strip).id 
            w.save
          end
	    end
          # Necessary to handle direct link to note from timelogs and putting the right start time in issue
          noteid = 1
          # Comments and status/resolution/keywords changes
          ticket.ticket_changes.group_by(&:time).each do |time, changeset|
              status_change = changeset.select {|change| change.field == 'status'}.first
              resolution_change = changeset.select {|change| change.field == 'resolution'}.first
              keywords_change = changeset.select {|change| change.field == 'keywords'}.first
              comment_change = changeset.select {|change| change.field == 'comment'}.first
              # Handle more ticket changes (owner, component, milestone, priority, summary, type, done_ratio and hours)
              assigned_change = changeset.select {|change| change.field == 'owner'}.first
              category_change = changeset.select {|change| change.field == 'component'}.first
              version_change = changeset.select {|change| change.field == 'milestone'}.first
              priority_change = changeset.select {|change| change.field == 'priority'}.first
              subject_change = changeset.select {|change| change.field == 'summary'}.first
              tracker_change = changeset.select {|change| change.field == 'type'}.first
              time_change = changeset.select {|change| change.field == 'hours'}.first

              # If it's the first note then we set the start working time to handle calendar and gantts
              if noteid == 1
                i.start_date = time
              end

              n = Journal.new :notes => (comment_change ? encode(comment_change.newvalue) : ''),
                              :created_on => time
              n.user = find_or_create_user(changeset.first.author)
              n.journalized = i
              if status_change &&
                   STATUS_MAPPING[status_change.oldvalue] &&
                   STATUS_MAPPING[status_change.newvalue] &&
                   (STATUS_MAPPING[status_change.oldvalue] != STATUS_MAPPING[status_change.newvalue])
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => PROP_MAPPING['status'],
                                               :old_value => STATUS_MAPPING[status_change.oldvalue].id,
                                               :value => STATUS_MAPPING[status_change.newvalue].id)
              end
              if resolution_change
                n.details << JournalDetail.new(:property => 'cf',
                                               :prop_key => custom_field_map['resolution'].id,
                                               :old_value => resolution_change.oldvalue,
                                               :value => resolution_change.newvalue)
                # Add a change for the done_ratio
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => 'done_ratio',
                                               :old_value => RATIO_MAPPING[resolution_change.oldvalue],
                                               :value => RATIO_MAPPING[resolution_change.newvalue])
                # Arbitrary set the due time to the day the ticket was resolved for calendar and gantts
                case RATIO_MAPPING[resolution_change.newvalue]
                when 0
                  i.due_date = nil
                when 100
                  i.due_date = time
                end               
              end
              if keywords_change
                n.details << JournalDetail.new(:property => 'cf',
                                               :prop_key => custom_field_map['keywords'].id,
                                               :old_value => keywords_change.oldvalue,
                                               :value => keywords_change.newvalue)
              end
              # Handle assignement/owner changes
              if assigned_change
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => PROP_MAPPING['owner'],
                                               :old_value => find_or_create_user(assigned_change.oldvalue, true),
                                               :value => find_or_create_user(assigned_change.newvalue, true))
              end
              # Handle component/category changes
              if category_change
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => PROP_MAPPING['component'],
                                               :old_value => issues_category_map[category_change.oldvalue],
                                               :value => issues_category_map[category_change.newvalue])
              end
              # Handle version/mileston changes
              if version_change
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => PROP_MAPPING['milestone'],
                                               :old_value => version_map[version_change.oldvalue],
                                               :value => version_map[version_change.newvalue])
              end
              # Handle priority changes
              if priority_change
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => PROP_MAPPING['priority'],
                                               :old_value => PRIORITY_MAPPING[priority_change.oldvalue],
                                               :value => PRIORITY_MAPPING[priority_change.newvalue])
              end
              # Handle subject/summary changes
              if subject_change
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => PROP_MAPPING['summary'],
                                               :old_value => encode(subject_change.oldvalue),
                                               :value => encode(subject_change.newvalue))
              end
              # Handle tracker/type (bug, feature) changes
              if tracker_change
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => PROP_MAPPING['type'],
                                               :old_value => TRACKER_MAPPING[tracker_change.oldvalue] || DEFAULT_TRACKER,
                                               :value => TRACKER_MAPPING[tracker_change.newvalue] || DEFAULT_TRACKER)
              end              
              # Add timelog entries for each time changes (from timeandestimation plugin)
              if time_change && time_change.newvalue != '0' && time_change.newvalue != ''
                t = TimeEntry.new(:project => @target_project, 
                                  :issue => i, 
                                  :user => n.user,
                                  :spent_on => time,
                                  :hours => time_change.newvalue,
                                  :created_on => time,
                                  :updated_on => time,
                                  :activity_id => TimeEntryActivity.find_by_position(2).id,
                                  :comments => "#{convert_wiki_text(n.notes.each_line.first.chomp) unless !n.notes.each_line.first}... \"more\":/issues/#{i.id}#note-#{noteid}")
                t.save
                t.errors.to_a.each{|msg| puts msg }
              end
              # Set correct changetime of the issue
              next unless i.save
              n.save unless n.details.empty? && n.notes.blank?
              noteid += 1
          end

          # Attachments
          ticket.attachments.each do |attachment|
              print "missing attachment: #{attachment.original_filename}\n" unless attachment.exist?
              print "                    (trac path: #{attachment.trac_fullpath})\n" unless attachment.exist?
           next unless attachment.exist?
              attachment.open {
                a = Attachment.new :created_on => attachment.time
                a.file = attachment
                a.author = find_or_create_user(attachment.author)
                a.container = i
                a.description = attachment.description
                if a.save
                migrated_ticket_attachments += 1 if a.save
                else
                  # errors can be caused by file size restrictions see settings.yml attachment_max_size
                  save_errors_ticket_attachments += 1
                end
              }
          end

          # Custom fields
          custom_values = ticket.customs.inject({}) do |h, custom|
            if custom_field = custom_field_map[custom.name]
              h[custom_field.id] = custom.value
              migrated_custom_values += 1
            end
            h
          end
          if custom_field_map['resolution'] && !ticket.resolution.blank?
            custom_values[custom_field_map['resolution'].id] = ticket.resolution
          end
          if custom_field_map['keywords'] && !ticket.keywords.blank?
            custom_values[custom_field_map['keywords'].id] = ticket.keywords
          end
          if custom_field_map['tracid'] 
            custom_values[custom_field_map['tracid'].id] = ticket.id
          end

         if !ticket.version.blank? && custom_field_map['found_in_version']
           found_in = version_map[ticket.version]
            if !found_in.nil?
              puts "Issue #{i.id} found in #{found_in.name.to_s} (#{found_in.id.to_s}) - trac: #{ticket.version}"
            else
              #TODO: add better error management here...
              puts "Issue #{i.id} : ouch...  - trac: #{ticket.version}"  
            end 
            custom_values[custom_field_map['found_in_version'].id] = found_in.id.to_s
            STDOUT.flush
          end

          i.custom_field_values = custom_values
          i.save_custom_field_values
        end

        # update issue id sequence if needed (postgresql)
        Issue.connection.reset_pk_sequence!(Issue.table_name) if Issue.connection.respond_to?('reset_pk_sequence!')
        puts if migrated_tickets < tickets_total

          if parent_issue_map.length > 0
            who = "Migrating ticket relations"
            migrated_ticket_relations = 0
            parent_issue_map.each do |child_id, parent_id|
              child_issue = Issue.find(child_id)
              last_updated_on = child_issue.updated_on
              if child_issue.update_attributes(:parent_issue_id => parent_id)
                # reset timestamp
                child_issue.update_column(:updated_on, last_updated_on)
                migrated_ticket_relations += 1
              else
                puts "ERROR: #{parent_id} <- #{child_id}"
              end
              simplebar(who, migrated_ticket_relations, parent_issue_map.length)
            end
          end

end # end of skipTickets debug switch

        # Wiki
        #ActiveRecord::Base.logger = Logger.new(STDOUT)
        who = "Migrating wiki"
        if wiki.save
          wiki_edits_total = TracWikiPage.count
          TracWikiPage.order('name, version').all.each do |page|
            # Do not migrate Trac manual wiki pages
            if TRAC_WIKI_PAGES.include?(page.name) then
              wiki_edits_total -= 1
              next
            end
            p = wiki.find_or_new_page(page.name)
            new_page = false
            if p.new_record?
              p.content = WikiContent.new(:page => p)
              new_page = true
            end
            p.content.text = page.text
            p.content.author = find_or_create_user(page.author) unless page.author.blank? || page.author == 'trac'
            p.content.comments = page.comment
            p.new_record? ? p.save : p.content.save
            migrated_wiki_edits += 1
            simplebar(who, migrated_wiki_edits, wiki_edits_total)

            next if p.content.new_record?

            # Attachments
            debug_wiki = false
            print "Wikipage: #{page.name}\n" if debug_wiki
            page.attachments.each do |attachment|
              print "missing attachment: #{attachment.original_filename}\n" unless attachment.exist?
              print "                    (trac path: #{attachment.trac_fullpath})\n" unless attachment.exist?
              next unless attachment.exist?
              print "          a: #{attachment.filename}\n" if debug_wiki
              exists_in_page = false
              # check if attachment already exists for this page
              p.attachments.each do |existing_attachment|
                print "          ?= exa: #{existing_attachment.filename}" if debug_wiki
                exists_in_page = true if existing_attachment.filename == attachment.filename
                break if exists_in_page
              end
              next if exists_in_page
              print '             -> create' if debug_wiki
              attachment.open {
                a = Attachment.new :created_on => attachment.time
                a.file = attachment
                a.author = find_or_create_user(attachment.author)
                a.description = attachment.description
                a.container = p
                if a.save
                  migrated_wiki_attachments += 1
                else
                  # errors can be caused by file size restrictions see settings.yml attachment_max_size
                  save_errors_wiki_attachments += 1
                  print '             ERROR on save' if debug_wiki
                end
              }
              print "\n" if debug_wiki
            end
          end

        end
        puts if migrated_wiki_edits < wiki_edits_total

        # Now load each wiki page and transform its content into textile format
        puts "\nTransform texts to textile format:"
    
        wiki_pages_count = 0
        issues_count = 0
        milestone_wiki_count = 0

        who = "   in Wiki contents"
        wiki_content_total = WikiContent.count
        wiki_content_count = 0
        WikiContent.all.each do |wiki|
          ([wiki] + wiki.versions).each do |version|
            last_updated_on = version.updated_on
            version.text = convert_wiki_text(version.text)
            version.save
            # reset timestamp
            version.update_column(:updated_on, last_updated_on)
        end
          # to only keep the original history:
          # whipeout the new version which has been just created on save
          wiki.versions.reload
          wiki.versions.last.delete
          wiki_content_count += 1
          simplebar(who, wiki_content_count, wiki_content_total)
        end
        puts if wiki_content_count < wiki_content_total
        
        who = "   in Issues"
        #issues_total = TICKET_MAP.length #works with Ruby <= 1.8.6
        issues_total = TICKET_MAP.count #works with Ruby >= 1.8.7
        TICKET_MAP.each do |newId|
          issues_count += 1
          simplebar(who, issues_count, issues_total)
          next if newId.nil?
          issue = findIssue(newId)
          last_updated_on = issue.updated_on
          next if issue.nil?
          # convert issue description
          issue.description = convert_wiki_text(issue.description)
          # Converted issue comments had their last updated time set to the day of the migration (bugfix)
          next unless issue.save
	  # reset timestamp
          issue.update_column(:updated_on, last_updated_on)          
          # convert issue journals
          issue.journals.all.each do |journal|
            journal.update_column(:notes, convert_wiki_text(journal.notes)) # Avoid triggering callbacks: preserve timestamps
          end
        end
        puts if issues_count < issues_total

        who = "   in Milestone descriptions"
        #milestone_wiki_total = milestone_wiki.length #works with Ruby <= 1.8.6
        milestone_wiki_total = milestone_wiki.count #works with Ruby >= 1.8.7
        milestone_wiki.each do |name|
          milestone_wiki_count += 1
          simplebar(who, milestone_wiki_count, milestone_wiki_total)
          p = wiki.find_page(name)            
          next if p.nil?
          p.content.update_column(:text, convert_wiki_text(p.content.text))  # Avoid triggering callbacks: preserve timestamps
        end
        puts if milestone_wiki_count < milestone_wiki_total

        who = "Close completed milestones"
        milestones_closed_count = 0
        # :status => (!milestone.completed.blank? ? 'closed' : 'open')
        milestones_closed.each do |vid|
          milestones_closed_count +=1
          simplebar(who, milestones_closed_count, milestones_closed.length)
          v = Version.find(vid)
          v.status = 'closed'
          print 'Error on updating closed version' if !v.save
        end

        puts
        puts "Components:      #{migrated_components}/#{components_total}"
        puts "Milestones:      #{migrated_milestones}/#{milestones_total}"
        puts "Tickets:         #{migrated_tickets}/#{tickets_total}"
        puts "Ticket files:    #{migrated_ticket_attachments}/" + TracAttachment.where("type = 'ticket'").count.to_s
        puts "                 Errors on save ( #{save_errors_ticket_attachments})! This can be caused by file size restrictions. See settings.yml attachment_max_size" if save_errors_ticket_attachments > 0
        puts "Custom values:   #{migrated_custom_values}/#{TracTicketCustom.count}"
        puts "Wiki edits:      #{migrated_wiki_edits}/#{wiki_edits_total}"
        puts "Wiki files:      #{migrated_wiki_attachments}/" + TracAttachment.where("type = 'wiki'").count.to_s
        puts "                 Errors on save ( #{save_errors_wiki_attachments})! This can be caused by file size restrictions. See settings.yml attachment_max_size" if save_errors_wiki_attachments > 0
      end
      
      def self.findIssue(id)
        return Issue.find(id)
      rescue ActiveRecord::RecordNotFound
        puts "[#{id}] not found"
        nil
      end
      
      def self.limit_for(klass, attribute)
        klass.columns_hash[attribute.to_s].limit
      end

      def self.encoding(charset)
        @charset = charset
      end

      def self.lookup_database_version
        f = TracSystem.find_by_name("database_version")
        @@database_version = f.value.to_i
      end

      def self.database_version
        @@database_version
      end

      def self.set_trac_directory(path)
        @@trac_directory = path
        raise "This directory doesn't exist!" unless File.directory?(path)
        raise "#{trac_attachments_directory} doesn't exist!" unless File.directory?(trac_attachments_directory)
        @@trac_directory
      rescue Exception => e
        puts e
        return false
      end

      def self.trac_directory
        @@trac_directory
      end

      def self.set_trac_adapter(adapter)
        return false if adapter.blank?
        raise "Unknown adapter: #{adapter}!" unless %w(sqlite3 mysql postgresql).include?(adapter)
        # If adapter is sqlite or sqlite3, make sure that trac.db exists
        raise "#{trac_db_path} doesn't exist!" if %w(sqlite3).include?(adapter) && !File.exist?(trac_db_path)
        @@trac_adapter = adapter
      rescue Exception => e
        puts e
        return false
      end

      def self.set_trac_db_host(host)
        return nil if host.blank?
        @@trac_db_host = host
      end

      def self.set_trac_db_port(port)
        return nil if port.to_i == 0
        @@trac_db_port = port.to_i
      end

      def self.set_trac_db_name(name)
        return nil if name.blank?
        @@trac_db_name = name
      end

      def self.set_trac_db_username(username)
        @@trac_db_username = username
      end

      def self.set_trac_db_password(password)
        @@trac_db_password = password
      end

      def self.set_trac_db_schema(schema)
        @@trac_db_schema = schema
      end

      mattr_reader :trac_directory, :trac_adapter, :trac_db_host, :trac_db_port, :trac_db_name, :trac_db_schema, :trac_db_username, :trac_db_password

      def self.trac_db_path; "#{trac_directory}/db/trac.db" end
      def self.trac_attachments_directory; "#{trac_directory}/files/attachments" end

      def self.target_project_identifier(identifier)
        project = Project.find_by_identifier(identifier)
        if !project
          # create the target project
          project = Project.new :name => identifier.humanize,
                                :description => ''
          project.identifier = identifier
          puts "Unable to create a project with identifier '#{identifier}'!" unless project.save
          # enable issues and wiki for the created project
          # Enable only a minimal set of modules by default
          project.enabled_module_names = ['issue_tracking', 'wiki']
        else
          puts
          puts "This project already exists in your Redmine database."
          print "Are you sure you want to append data to this project ? [Y/n] "
          STDOUT.flush
          exit if STDIN.gets.match(/^n$/i)
        end
        project.trackers << TRACKER_BUG unless project.trackers.include?(TRACKER_BUG)
        project.trackers << TRACKER_FEATURE unless project.trackers.include?(TRACKER_FEATURE)
        project.trackers << TRACKER_SUPPORT unless project.trackers.include?(TRACKER_SUPPORT)
        #new trackers for trac mig.
         project.trackers << TRACKER_TASK unless project.trackers.include?(TRACKER_TASK)
         project.trackers << TRACKER_CONFIG unless project.trackers.include?(TRACKER_CONFIG)
        @target_project = project.new_record? ? nil : project
        @target_project.reload
      end

      def self.connection_params
        if trac_adapter == 'sqlite3'
          {:adapter => 'sqlite3',
           :database => trac_db_path}
        else
          {:adapter => trac_adapter,
           :database => trac_db_name,
           :host => trac_db_host,
           :port => trac_db_port,
           :username => trac_db_username,
           :password => trac_db_password,
           :schema_search_path => trac_db_schema
          }
        end
      end

      def self.establish_connection
        constants.each do |const|
          klass = const_get(const)
          next unless klass.respond_to? 'establish_connection'
          klass.establish_connection connection_params
        end
      end

      def self.encode(text)
        if RUBY_VERSION < '1.9'
          @ic ||= Iconv.new('UTF-8', @charset)
          @ic.iconv text
        else
          text.to_s.force_encoding(@charset).encode('UTF-8')
        end
      end
    end

    puts
    if Redmine::DefaultData::Loader.no_data?
      puts "Redmine configuration need to be loaded before importing data."
      puts "Please, run this first:"
      puts
      puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
      exit
    end

    puts "WARNING: a new project will be added to Redmine during this process."
    print "Are you sure you want to continue ? [y/N] "
    STDOUT.flush
    break unless STDIN.gets.match(/^y$/i)
    puts

    DEFAULT_PORTS = {'mysql' => 3306, 'postgresql' => 5432}

    prompt('Trac directory') {|directory| TracMigrate.set_trac_directory directory.strip}
    prompt('Trac database adapter (sqlite3, mysql2, postgresql)', :default => 'postgresql') {|adapter| TracMigrate.set_trac_adapter adapter}
    unless %w(sqlite3).include?(TracMigrate.trac_adapter)
      prompt('Trac database host', :default => 'localhost') {|host| TracMigrate.set_trac_db_host host}
      prompt('Trac database port', :default => DEFAULT_PORTS[TracMigrate.trac_adapter]) {|port| TracMigrate.set_trac_db_port port}
      prompt('Trac database name') {|name| TracMigrate.set_trac_db_name name}
      prompt('Trac database schema') {|schema| TracMigrate.set_trac_db_schema schema}
      prompt('Trac database username') {|username| TracMigrate.set_trac_db_username username}
      prompt('Trac database password') {|password| TracMigrate.set_trac_db_password password}
    end
    prompt('Trac database encoding', :default => 'UTF-8') {|encoding| TracMigrate.encoding encoding}
    prompt('Target project identifier', :default => 'trac') {|identifier| TracMigrate.target_project_identifier identifier.downcase}
    puts

    old_notified_events = Setting.notified_events
    old_password_min_length = Setting.password_min_length
    begin
      # Turn off email notifications temporarily
      Setting.notified_events = []
      Setting.password_min_length = 4
      # Run the migration
      TracMigrate.migrate
    ensure
      # Restore previous settings
      Setting.notified_events = old_notified_events
      Setting.password_min_length = old_password_min_length
    end
  end


  desc 'Subversion migration script'
  task :migrate_svn_commit_properties => :environment do

    require 'redmine/scm/adapters/abstract_adapter'
    require 'redmine/scm/adapters/subversion_adapter'
    require 'rexml/document'
    require 'uri'
    require 'tempfile'

    module SvnMigrate 
        TICKET_MAP = []

        class Commit
          attr_accessor :revision, :message, :author
          
          def initialize(attributes={})
            self.author = attributes[:author] || ""
            self.message = attributes[:message] || ""
            self.revision = attributes[:revision]
          end
        end
        
        class SvnExtendedAdapter < Redmine::Scm::Adapters::SubversionAdapter
        
            def set_author(path=nil, revision=nil, author=nil)
              path ||= ''

              cmd = "#{SVN_BIN} propset svn:author --quiet --revprop -r #{revision}  \"#{author}\" "
              cmd << credentials_string
              cmd << ' ' + target(URI.escape(path))

              shellout(cmd) do |io|
                begin
                  loop do 
                    line = io.readline
                    puts line
                  end
                rescue EOFError
                end  
              end

              raise if $? && $?.exitstatus != 0

            end

            def set_message(path=nil, revision=nil, msg=nil)
              path ||= ''

              Tempfile.open('msg') do |tempfile|

                # This is a weird thing. We need to cleanup cr/lf so we have uniform line separators              
                tempfile.print msg.gsub(/\r\n/,'\n')
                tempfile.flush

                filePath = tempfile.path.gsub(File::SEPARATOR, File::ALT_SEPARATOR || File::SEPARATOR)

                cmd = "#{SVN_BIN} propset svn:log --quiet --revprop -r #{revision}  -F \"#{filePath}\" "
                cmd << credentials_string
                cmd << ' ' + target(URI.escape(path))

                shellout(cmd) do |io|
                  begin
                    loop do 
                      line = io.readline
                      puts line
                    end
                  rescue EOFError
                  end  
                end

                raise if $? && $?.exitstatus != 0

              end
              
            end
        
            def messages(path=nil)
              path ||= ''

              commits = Array.new

              cmd = "#{SVN_BIN} log --xml -r 1:HEAD"
              cmd << credentials_string
              cmd << ' ' + target(URI.escape(path))
                            
              shellout(cmd) do |io|
                begin
                  doc = REXML::Document.new(io)
                  doc.elements.each("log/logentry") do |logentry|
                    if logentry.elements['msg'].nil? || logentry.elements['author'].nil?
                       next 
                    end

                    commits << Commit.new(
                                                {
                                                  :revision => logentry.attributes['revision'].to_i,
                                                  :message => logentry.elements['msg'].text,
                                                  :author => logentry.elements['author'].text
                                                })
                  end
                rescue => e
                  puts"Error !!!"
                  puts e
                end
              end
              return nil if $? && $?.exitstatus != 0
              commits
            end
          
        end
        
        def self.migrate_authors
          svn = self.scm          
          commits = svn.messages(@svn_url)
          commits.each do |commit| 
            orig_author_name = commit.author
            new_author_name = orig_author_name
            
            # TODO put your Trac/SVN/Redmine username mapping here:
          #  if (commit.author == 'TracX')
          #     new_author_name = 'RedmineY'
          #  elsif (commit.author == 'gilles')
          #     new_author_name = 'gcornu'
            #elsif (commit.author == 'seco')
            #...
         #   else
         #      new_author_name = 'RedmineY'
         #   end
            
            if (new_author_name != orig_author_name)
              scm.set_author(@svn_url, commit.revision, new_author_name)
              puts "r#{commit.revision} - Author replaced: #{orig_author_name} -> #{new_author_name}"
            else
              puts "r#{commit.revision} - Author kept: #{orig_author_name} unchanged "
            end
          end
        end
        
         def self.migrate_messages

        project = Project.where(name: @@redmine_project)
        if !project
          puts "Could not find project identifier '#{@@redmine_project}'"
          raise
        end

        tid = IssueCustomField.find_by(name: "TracID" )
        if !tid
          puts "Could not find issue custom field 'TracID'"
          raise
        end
        
        puts "Yes, we get here"

        Issue.where(project_id: project).find_each do |issue|
          val = nil
          issue.custom_values.each do |value|
            if value.custom_field.id == tid.id
              val = value
              break
            end
          end

          TICKET_MAP[val.value.to_i] = issue.id if !val.nil?
          puts "Mapping TracID #{val} to Redmine #{issue.id}"
        end

          
          svn = self.scm          
          msgs = svn.messages(@svn_url)
          puts "Got #{msgs.length} commits"
          msgs.each do |commit| 
            puts "Checking message #{commit.revision}"
          
            newText = convert_wiki_text(commit.message)
            puts "#{commit.message}"
            puts "#{newText}" 
            #if newText != commit.message             
            if newText != commit.message

              puts "Updating message #{commit.revision}"
              
              # Marcel Nadje enhancement, see http://www.redmine.org/issues/2748#note-3
              # Hint: enable charset conversion if needed...
              #newText = Iconv.conv('CP1252', 'UTF-8', newText)
              
              scm.set_message(@svn_url, commit.revision, newText)
            end
          end
          
          
        end
        
        # Basic wiki syntax conversion
        def self.convert_wiki_text(text)
          convert_wiki_text_mapping(text, TICKET_MAP)
        end
        
        def self.set_svn_url(url)
          @@svn_url = url
        end

        def self.set_svn_username(username)
          @@svn_username = username
        end

        def self.set_svn_password(password)
          @@svn_password = password
        end

        def self.set_redmine_project_identifier(identifier)
          @@redmine_project = identifier
        end
      
        def self.scm
          # Thomas Recloux fix, see http://www.redmine.org/issues/2748#note-1
          # The constructor of the SvnExtendedAdapter has ony got four parameters, 
          # => parameters 5,6 and 7 removed
          @scm ||= SvnExtendedAdapter.new @@svn_url, @@svn_url, @@svn_username, @@svn_password
          #@scm ||= SvnExtendedAdapter.new @@svn_url, @@svn_url, @@svn_username, @@svn_password, 0, "", nil
          @scm
        end
    end

    puts
    prompt('Subversion repository url') {|repository| SvnMigrate.set_svn_url repository.strip}
    prompt('Subversion repository username') {|username| SvnMigrate.set_svn_username username}
    prompt('Subversion repository password') {|password| SvnMigrate.set_svn_password password}
    puts
        
    author_migration_enabled = unsafe_prompt('1) Start Migration of SVN Commit Authors (y,n)?', {:default => 'n'}) == 'y'
    puts
    if author_migration_enabled
      puts "WARNING: Some (maybe all) commit authors will be replaced"
      print "Are you sure you want to continue ? [y/N] "
      break unless STDIN.gets.match(/^y$/i)
      
     # SvnMigrate.migrate_authors
    end

    message_migration_enabled = unsafe_prompt('2) Start Migration of SVN Commit Messages (y,n)?', {:default => 'n'}) == 'y'
    puts
    if message_migration_enabled
      if Redmine::DefaultData::Loader.no_data?
        puts "Redmine configuration need to be loaded before importing data."
        puts "Please, run this first:"
        puts
        puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
        exit
      end
  
      puts "WARNING: all commit messages with references to trac pages will be modified"
      print "Are you sure you want to continue ? [y/N] "
      break unless STDIN.gets.match(/^y$/i)
      puts
  
      prompt('Redmine project identifier') {|identifier| SvnMigrate.set_redmine_project_identifier identifier}
      puts
  
      $stdout.reopen("/tmp/svn_migration.log", "w")
      $stdout.sync = true
      $stderr.reopen($stdout)
      #SvnMigrate.migrate_authors
      SvnMigrate.migrate_messages
    end
  end

  # Prompt
  def prompt(text, options = {}, &block)
    default = options[:default] || ''
    while true
      print "#{text} [#{default}]: "
      STDOUT.flush
      value = STDIN.gets.chomp!
      value = default if value.blank?
      break if yield value
    end
  end

  # Sorry, I had troubles to intagrate 'prompt' and quickly went this way...
  def unsafe_prompt(text, options = {})
    default = options[:default] || ''
    print "#{text} [#{default}]: "
    value = STDIN.gets.chomp!
    value = default if value.blank?
    value
  end

  # Basic wiki syntax conversion
  def convert_wiki_text_mapping(text, ticket_map = [])
        # Hide links
        def wiki_links_hide(src)
          @wiki_links = []
          @wiki_links_hash = "####WIKILINKS#{src.hash.to_s}####"
          src.gsub(/(\[\[.+?\|.+?\]\])/) do
            @wiki_links << $1
            @wiki_links_hash
          end
        end
        # Restore links
        def wiki_links_restore(src)
          @wiki_links.each do |s|
            src = src.sub("#{@wiki_links_hash}", s.to_s)
          end
          src
        end
        # Hidding code blocks
        def code_hide(src)
          @code = []
          @code_hash = "####CODEBLOCK#{src.hash.to_s}####"
          src.gsub(/(\{\{\{.+?\}\}\}|`.+?`)/m) do
            @code << $1
            @code_hash
          end
        end
        # Convert code blocks
        def code_convert(src)
          @code.each do |s|
            s = s.to_s
            if s =~ (/`(.+?)`/m) || s =~ (/\{\{\{(.+?)\}\}\}/) then
              # inline code
              s = s.replace("@#{$1}@")
            else
              # We would like to convert the Code highlighting too
              # This will go into the next line.
              shebang_line = false
              # Regular expression for start of code
              pre_re = /\{\{\{/
              # Code highlighting...
              shebang_re = /^\#\!([a-z]+)/
              # Regular expression for end of code
              pre_end_re = /\}\}\}/
      
              # Go through the whole text..extract it line by line
              s = s.gsub(/^(.*)$/) do |line|
                m_pre = pre_re.match(line)
                if m_pre
                  line = '<pre>'
                else
                  m_sl = shebang_re.match(line)
                  if m_sl
                    shebang_line = true
                    line = '<code class="' + m_sl[1] + '">'
                  end
                  m_pre_end = pre_end_re.match(line)
                  if m_pre_end
                    line = '</pre>'
                    if shebang_line
                      line = '</code>' + line
                    end
                  end
                end
                line
              end
            end
            src = src.sub("#{@code_hash}", s)
          end
          src
        end

    def self.convert_lists(src)
      converted = []
      in_list = false
      level_count = 0
      last_indent = 0
      is_bullet_list = false
      indicator_length = 0

      src.lines.map.each do|line|
        # detect start and continuation of lists
        # eg:
        #    | * item 1
        #    | * item 2
        #    |   continuation of line 2
        #    |    * sub item of 2
        #    | * item 3
        #    |out of list
        is_list_item = false
        line.scan(/^(\ +)([\*-]|\d+\.)/) { |indent, indicator|
          is_list_item = indent != nil
          is_bullet_list = indicator == '*'
          indicator_length = indicator.to_s.length
          if indent.to_s.length > last_indent
            level_count += 1
          end
          if indent.to_s.length < last_indent
            level_count -= 1
          end
          level_count = 0 if level_count < 0 # avoid negative level counts
          last_indent = indent.to_s.length
        }
        has_indent = line =~ /^\ +/
        is_list_start = is_list_item && !in_list
        in_list = is_list_start || (in_list && has_indent)

        if !in_list
          level_count = 0
          last_indent = 0
          converted << line
          next
        end

        if is_list_item
          if is_bullet_list
            #      bullet
            converted << (line.sub(/^\ +[\*-] /) { |s| '*' * level_count + " " })
          else
            #      numbered
            converted << (line.gsub(/^\ +\d+\. /) { |s| '#' * level_count + " " })
          end
        else
          converted << (line.gsub(/^\ +/) { |s| ' ' * (level_count * indicator_length ) })
        end
      end
      converted.join()
    end

        # Hide code blocks
        text = code_hide(text)
    # Clean up trailing whitespace
    text = text.gsub(/([^ \t\r\n]*?)[ \t]+$/, '\1')
        # New line
        text = text.gsub(/\[\[[Bb][Rr]\]\]/, "\n") # This has to go before the rules below
    # Horizontal lines (need new line before)
    text = text.gsub(/\n(.*?)\n[\-]{4,}/m) { |s| ($1 ? "\n#{$1}\n" : "\n") + "\n----"}
        # Titles (only h1. to h6., and remove #...)
        text = text.gsub(/(?:^|^\ +)(\={1,6})\ (.+)\ (?:\1)(?:\ *(\ \#.*))?/) {|s| "\nh#{$1.length}. #{$2}#{$3}\n"}
        
        # External Links:
        #      [http://example.com/]
        text = text.gsub(/\[((?:https?|s?ftp)\:\S+)\]/, '\1')
        #      [http://example.com/ Example],[http://example.com/ "Example"]
        #      [http://example.com/ "Example for "Example""] -> "Example for 'Example'":http://example.com/
        text = text.gsub(/\[((?:https?|s?ftp)\:\S+)[\ \t]+([\"']?)(.+?)\2\]/) {|s| "\"#{$3.tr('"','\'')}\":#{$1}"}
        #      [mailto:some@example.com],[mailto:"some@example.com"]
        text = text.gsub(/\[mailto\:([\"']?)(.+?)\1\]/, '\2')
        
        # Ticket links:
    #      comment:ticket:1234:5
    text = text.gsub(/comment\:ticket\:(\d+?)\:(\d+?)/, '#\1#note-\2')
        #      [ticket:234 Text],[ticket:234 This is a test],[ticket:234 "This is a test"]
        #      [ticket:234 "Test "with quotes""] -> "Test 'with quotes'":issues/show/234
        text = text.gsub(/\[ticket\:(\d+)[\ \t]+([\"']?)(.+?)\2\]/) {|s| "\"#{$3.tr('"','\'')}\":/issues/show/#{$1}"}
        #      ticket:1234
        #      excluding ticket:1234:file.txt (used in macros)
        #      #1 - working cause Redmine uses the same syntax.
        text = text.gsub(/ticket\:(\d+?)([^\:])/, '#\1\2')

        # Source & attachments links:
        #      [source:/trunk/readme.txt Readme File],[source:"/trunk/readme.txt" Readme File],
        #      [source:/trunk/readme.txt],[source:"/trunk/readme.txt"]
        #       The text "Readme File" is not converted,
        #       cause Redmine's wiki does not support this.
        #      Attachments use same syntax.
        text = text.gsub(/\[(source|attachment)\:([\"']?)([^\"']+?)\2(?:\ +(.+?))?\]/, '\1:"\3"')
        #      source:"/trunk/readme.txt"
        #      source:/trunk/readme.txt - working cause Redmine uses the same syntax.
        text = text.gsub(/(source|attachment)\:([\"'])([^\"']+?)\2/, '\1:"\3"')

        # Milestone links:
        #      [milestone:"0.1.0 Mercury" Milestone 0.1.0 (Mercury)],
        #      [milestone:"0.1.0 Mercury"],milestone:"0.1.0 Mercury"
        #       The text "Milestone 0.1.0 (Mercury)" is not converted,
        #       cause Redmine's wiki does not support this.
        text = text.gsub(/\[milestone\:([\"'])([^\"']+?)\1(?:\ +(.+?))?\]/, 'version:"\2"')
        text = text.gsub(/milestone\:([\"'])([^\"']+?)\1/, 'version:"\2"')
        #      [milestone:0.1.0],milestone:0.1.0
        text = text.gsub(/\[milestone\:([^\ ]+?)\]/, 'version:\1')
        text = text.gsub(/milestone\:([^\ ]+?)/, 'version:\1')

        # Internal Links:
    #      [SomeLink Link description]
    text = text.gsub(/\[(?!wiki\:)(.+?)\s+(.+?)\]/) { |s| "[[#{$1.delete(',./?;|:')}|#{$2}]]" }
        #      ["Some Link"]
        text = text.gsub(/\[([\"'])(.+?)\1\]/) {|s| "[[#{$2.delete(',./?;|:')}]]"}
        #      [wiki:"Some Link" "Link description"],[wiki:"Some Link" Link description]
        text = text.gsub(/\[wiki\:([\"'])([^\]\"']+?)\1[\ \t]+([\"']?)(.+?)\3\]/) {|s| "[[#{$2.delete(',./?;|:')}|#{$4}]]"}
        #      [wiki:"Some Link"]
        text = text.gsub(/\[wiki\:([\"'])([^\]\"']+?)\1\]/) {|s| "[[#{$2.delete(',./?;|:')}]]"}
        #      [wiki:SomeLink]
        text = text.gsub(/\[wiki\:([^\s\]]+?)\]/) {|s| "[[#{$1.delete(',./?;|:')}]]"}
        #      [wiki:SomeLink Link description],[wiki:SomeLink "Link description"]
        text = text.gsub(/\[wiki\:([^\s\]\"']+?)[\ \t]+([\"']?)(.+?)\2\]/) {|s| "[[#{$1.delete(',./?;|:')}|#{$3}]]"}

        # Before convert CamelCase links, must hide wiki links with description.
        # Like this: [[http://www.freebsd.org|Hello FreeBSD World]]
        text = wiki_links_hide(text)
        # Links to CamelCase pages (not work for unicode)
        #      UsingJustWikiCaps,UsingJustWikiCaps/Subpage
    text = text.gsub(/([^!]|^)(^| )([A-Z][a-z]+[A-Z][a-zA-Z]+(?:\/[^\s[:punct:]]+)*)/) {|s|
      page_title = $3.delete('/')
      if WikiPage.where(:title => page_title).count > 0
        "#{$1}#{$2}[[#{page_title}]]"
      else
        "#{$1}#{$2}#{$3}"
      end
    }
        # Normalize things that were supposed to not be links
        # like !NotALink
        text = text.gsub(/(^| )!([A-Z][A-Za-z]+)/, '\1\2')
        # Now restore hidden links
        text = wiki_links_restore(text)
        
        # Revisions links
        text = text.gsub(/\[(\d+)\]/, 'r\1')
        # Ticket number re-writing
        text = text.gsub(/#(\d+)/) do |s|
          if $1.length < 10
            #ticket_map[$1.to_i] ||= $1
            "\##{ticket_map[$1.to_i] || $1}"
          else
            s
          end
        end
        
        # Highlighting
        text = text.gsub(/'''''([^\s])/, '_*\1')
        text = text.gsub(/([^\s])'''''/, '\1*_')
        text = text.gsub(/'''/, '*')
        text = text.gsub(/''/, '_')
        text = text.gsub(/__/, '+')
        text = text.gsub(/~~/, '-')
        text = text.gsub(/`/, '@')
        text = text.gsub(/,,/, '~')
        # Tables
        text = text.gsub(/\|\|/, '|')
        # Lists:
    text = convert_lists(text)
        # Images (work for only attached in current page [[Image(picture.gif)]])
        # need rules for:  * [[Image(wiki:WikiFormatting:picture.gif)]] (referring to attachment on another page)
        #                  * [[Image(ticket:1:picture.gif)]] (file attached to a ticket)
        #                  * [[Image(htdocs:picture.gif)]] (referring to a file inside project htdocs)
        #                  * [[Image(source:/trunk/trac/htdocs/trac_logo_mini.png)]] (a file in repository) 
        text = text.gsub(/\[\[image\((.+?)(?:,.+?)?\)\]\]/i, '!\1!')
        # TOC (is right-aligned, because that in Trac)
        text = text.gsub(/\[\[TOC(?:\((.*?)\))?\]\]/m) {|s| "{{>toc}}\n"}

        # Thomas Recloux enhancements, see http://www.redmine.org/issues/2748#note-1
        # Redmine needs a space between keywords "refs,ref,fix" and the issue number (#1234) in subversion commit messages.
        # TODO: rewrite it in a more regex-style way

        text = text.gsub("refs#", "refs #")
        text = text.gsub("Refs#", "refs #")
        text = text.gsub("REFS#", "refs #")
        text = text.gsub("ref#", "refs #")
        text = text.gsub("Ref#", "refs #")
        text = text.gsub("REF#", "refs #")

        text = text.gsub("fix#", "fixes #")
        text = text.gsub("Fix#", "fixes #")
        text = text.gsub("FIX#", "fixes #")
        text = text.gsub("fixes#", "fixes #")
        text = text.gsub("Fixes#", "fixes #")
        text = text.gsub("FIXES#", "fixes #")

        text = text.gsub("see#", "see #")
        text = text.gsub("See#", "See #")
        text = text.gsub("SEE#", "See #")

        text = text.gsub("TICKET#", "Ticket #")
        text = text.gsub("ticket#", "ticket #")
        text = text.gsub("Ticket#", "Ticket #")
        
        text = text.gsub("TICKETS#", "Tickets #")
        text = text.gsub("Tickets#", "Tickets #")
        text = text.gsub("tickets#", "tickets #")
       
        
        # Restore and convert code blocks
        text = code_convert(text)

        text
  end
  
  # Simple progress bar
  def simplebar(title, current, total, out = STDOUT)
    def get_width
      default_width = 80
      begin
        tiocgwinsz = 0x5413
        data = [0, 0, 0, 0].pack("SSSS")
        if out.ioctl(tiocgwinsz, data) >= 0 then
          rows, cols, xpixels, ypixels = data.unpack("SSSS")
          if cols >= 0 then
            cols
          else
            default_width
          end
        else
          default_width
        end
      rescue Exception
        default_width
      end
    end
    mark = "*"
    title_width = 40
    max = get_width - title_width - 10
    format = "%-#{title_width}s [%-#{max}s] %3d%%  %s"
    bar = current * max / total
    percentage = bar * 100 / max
    current == total ? eol = "\n" : eol ="\r"
    printf(format, title, mark * bar, percentage, eol)
    out.flush
  end
end 
