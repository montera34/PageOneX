require "fileutils"
require "open-uri"
require "net/http"
require "image_size"

class KioskoScraper

	KIOSKO_BASE_URL = "http://en.kiosko.net"
	KIOSKO_BASE_IMAGE_URL = "http://img.kiosko.net/"

	def self.use_local_images
		Pageonex::Application.config.use_local_images
	end

	# test like this in the rails console: 
	#   KioskoScraper::create_images(Date.today-1, Date.today, [Media.first])
	def self.create_images(start_date , end_date, media_list)

		images = []

		# create any local caching dirs that you need to
		if KioskoScraper.use_local_images
			kiosko_image_dir = "app/assets/images/kiosko"
			FileUtils.mkdir kiosko_image_dir unless File.directory? kiosko_image_dir
			media_list.each do |media|
				local_image_dir = "app/assets/images/kiosko/" + media.name
				FileUtils.mkdir local_image_dir unless File.directory? local_image_dir
			end
		end

		media_list.each do |media|
			(start_date..end_date).map do |date|

				img = Image.find_by_media_id_and_publication_date(media.id, date)
				if img==nil	# ensure only one entry per front page in the images table
					img = Image.new
					img.source_url = KioskoScraper::KIOSKO_BASE_IMAGE_URL + date.to_formatted_s(:kiosko_file_datestamp) + "/#{media.country_code}/#{media.name}.750.jpg"
					img.publication_date = date
					img.media_id = media.id
					img.image_name = media.name + "-" + img.publication_date.to_formatted_s(:file_datestamp)
					if KioskoScraper.use_local_images
						# download the image locally
						img.local_path = 'kiosko/' + media.name + "/" + img.image_name + ".jpg"
						full_local_path = "app/assets/images/" + img.local_path
						begin
							File.open(full_local_path, "wb") { |f| f.write(open(img.source_url).read) }
							File.open(full_local_path,"rb") do |f|
								size_info = ImageSize.new(f.read).get_size
								img.size = "#{size_info[0]}x#{size_info[1]}"
							end
							img.missing = false
						rescue
							# image doesn't exist on their server :-(
							img.local_path = '404.jpg'
							img.size = '750x951'
							img.missing = true
						end
					else
						# verify the url is there to see
						url = URI.parse(img.source_url)
						request = Net::HTTP.new(url.host, url.port)
						response = request.request_head(url.path)
						img.size = '750x951' #!!this value of pixels is 'hard coded' so it gives wrong values for long newspapers
						img.missing = (response.code != "200")							 
					end
					img.save
				end
				images << img

			end
		end

		images

	end

	# update the newspaper info from kiosko, saving to 'public/kiosko_scraped.csv'
	def self.scrape_media_to_csv

		puts "Scraping media info from "+KioskoScraper::KIOSKO_BASE_URL

		home_page = self.cached_get_url KioskoScraper::KIOSKO_BASE_URL
		groups_urls = []

		home_page.css("#menu a[title]").each do |menu_item| 
			groups_urls << KioskoScraper::KIOSKO_BASE_URL + menu_item.attributes["href"].value
		end

		all_media = []
		scraped_urls = []
		scraped_media_names = []

		groups_urls.each do |url|
			group_page = self.cached_get_url url
			region_links = group_page.css('.auxCol li.reg a')
			
			group_page.css('.titPpal h2 a').each do |a_element|
				category_url =  KioskoScraper::KIOSKO_BASE_URL + a_element.attributes['href'].value
				category_page = self.cached_get_url category_url
				extract_media_from_page(category_page).each do |media|
					unless scraped_media_names.include? media.name
						all_media << media
						scraped_media_names << media.name
					end
				end
				scraped_urls << category_url
			end

			unless region_links.length==0
				# visit each region page and grab papers
				region_links.each do |region_link|
					region_url = KioskoScraper::KIOSKO_BASE_URL + region_link.attributes['href'].value
					unless scraped_urls.include? region_url # make sure we haven't done it already
						region_page = self.cached_get_url region_url
						extract_media_from_page(region_page).each do |media|
							unless scraped_media_names.include? media.name
								all_media << media
								scraped_media_names << media.name
							end
						end
						scraped_urls << region_url
					end
				end
			end
		end

		# backwards compatability
		all_media.sort_by! { |media| media.country+media.display_name }

		# write a CSV
		CSV.open("public/kiosko_scraped.csv", "wb") do |csv|
  		csv << ['country','country_code','display_name','name','url']
  		all_media.each do |media|
  			csv << [media.country, media.country_code, media.display_name, media.name, media.url]
  		end
		end

	end

	def self.update_media_from_csv csv_file
		first_row = false
		unless File.exists? csv_file
			puts 'ERROR: '+csv_file+' does not exists'
			exit
		end

		# mark them all not working before updating
		Media.update_all(:working=>false)
		i = 0
		CSV.foreach(csv_file) do |row|
			if first_row==false
				first_row = true
				next
			end
			Media.find_or_create_by_name(row[3]).update_attributes({
				:country => row[0],
				:country_code => row[1],
				:display_name => row[2],
				:url => row[4],
				:working => true
			})
			i = i + 1		
			puts 'row ' + i.to_s
		end
		puts 'Media update from '+csv_file+' finished'
	end

	private

		# be nice to kiosko and cache the pages locally while we scrape
		def self.cached_get_url(url, bypass_cache=false)
			print url
			content = Rails.cache.fetch url
			if content.nil? or bypass_cache
				content = open(url).read
				Rails.cache.write(url,content)
				print " (added to cache)"
			else 
				print " (from cache)"
			end
			puts ''
			Nokogiri::HTML(content)
		end

		# make media out of a page of images
		def self.extract_media_from_page(page)
			country_element = page.css('.auxCol .co strong a').first
			page.css('.expo li a.thcover').collect do |paper_img_link|
				unique_name = paper_img_link.attributes['href'].value.split('/').last.gsub('.html','')
				details_page_url = KioskoScraper::KIOSKO_BASE_URL + paper_img_link.attributes['href'].value
				details_page = self.cached_get_url(details_page_url)
				newspaper_url = details_page.css('.newspaper ul.tools li a').first.attributes['href'].value
				display_name = details_page.css('h1.titPaper').first.content
				Media.new(
					:name => unique_name,
					:country => country_element.content,
					:country_code => country_element.attributes["href"].value.split('/')[1],
					:url => newspaper_url,
					:display_name => display_name
				)
			end
		end

end


