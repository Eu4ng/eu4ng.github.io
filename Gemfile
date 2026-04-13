# frozen_string_literal: true

source "https://rubygems.org"

gem "jekyll-theme-chirpy", "~> 6.4", ">= 6.4.2"

group :test do
  gem "html-proofer", "~> 4.4"
end

# Windows and JRuby does not include zoneinfo files, so bundle the tzinfo-data gem
# and associated library.
platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

# Performance-booster for watching directories on Windows
gem "wdm", "~> 0.1.1", :platforms => [:mingw, :x64_mingw, :mswin]

# Lock `http_parser.rb` gem to `v0.6.x` on JRuby builds since newer versions of the gem
# do not have a Java counterpart.
gem "http_parser.rb", "~> 0.6.0", :platforms => [:jruby]

# Jekyll 플러그인

group :jekyll_plugins do
  gem "jekyll-compose" # 게시글 정보 자동 완성
  gem "jekyll-last-modified-at" # 게시글 업데이트 날짜 자동 기록
  gem "jekyll-redirect-from" # 이전 주소에서 새 주소로 리다이렉트
end