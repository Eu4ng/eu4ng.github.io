# frozen_string_literal: true

source "https://rubygems.org"

gem "jekyll-theme-chirpy", "~> 7.5"

gem "html-proofer", "~> 5.0", group: :test

platforms :windows, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem "wdm", "~> 0.2.0", :platforms => [:windows]

# Jekyll 플러그인

group :jekyll_plugins do
  gem "jekyll-compose" # 게시글 정보 자동 완성
  gem "jekyll-last-modified-at" # 게시글 업데이트 날짜 자동 기록
  gem "jekyll-redirect-from" # 이전 주소에서 새 주소로 리다이렉트
end
