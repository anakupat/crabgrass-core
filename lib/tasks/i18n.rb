require 'yaml'
require 'fileutils'
require 'crabgrass/boot'

def extract_keys()
  keys = {}
  ["app","lib","extensions","vendor/crabgrass_plugins"].each do |dir|

    # this will catch all non-commented-out lines that contain '.t'. It seems better to look at more lines and then distinguish $
    lines = `find #{dir} -type f -exec grep '\\.t' \\{\\} \\; | grep -v '^ *#'`.split "\n"

    lines.each do |line|

      # there could be multiple matches per line
      matches = line.scan(/:([0-9a-zA-Z_]+)\.t?/)
      # catches :standard.t and :standard.tcap

      matches.each do |match|
        (keys[match[0]] = true) if match
      end

      # again, look for multiple matches in line
      matches_i18n = line.scan(/I18n\.t(\(| )(:|'|")([0-9a-zA-Z_]+)(,|\)|'|"| )/)
      # catches I18n.t "less good", I18n.t("less good", blah), I18n.t 'less good', I18n.t('less good'), I18n.t :ok, I18n.t :ok, blah, I18n.t(:ok), etc..

      matches_i18n.each do |match_i18n|
        (keys[match_i18n[2]] = true) if match_i18n
      end

    end
  end

  keys
end

def load_data()
  unless File.exists?('tmp/en.yml')
    puts "skipping, no en.yml"
    exit
  end
  en = YAML.load_file('tmp/en.yml')['en']
  keys = extract_keys
  orphaned = en.keys - keys.keys
  missing = keys.keys - en.keys
  duplicates = []
  duplicate_hash = en.values.inject(Hash.new(0)) {|h,i| h[i] += 1; h}
  duplicate_hash.each do |value,count|
    duplicates << value if count > 1
  end
  return [en, keys, orphaned, missing, duplicates]
end

namespace :cg do
  namespace :i18n do

    desc "print translation report"
    task :report do
      en, keys, orphaned, missing, dups = load_data
      puts 'Total keys in yaml: %s' % en.keys.count
      puts 'Total keys in code: %s' % keys.keys.count
      puts 'Orphaned keys: %s (translated, but not in code)' % orphaned.count
      puts 'Missing keys: %s (in code, but not translated)' % missing.count
      puts 'Duplicate values: %s' % dups.count
      puts
      puts 'run "rake cg:i18n:orphaned" for a list of orphaned keys'
      puts 'run "rake cg:i18n:missing" for a list of missing keys'
      puts 'run "rake cg:i18n:dups" for a list of duplicate values'
      puts 'run "rake cg:i18n:bundle" to combine the keys in locales/en/*.yml to tmp/en.yml'
    end

    desc "list keys not in code"
    task :orphaned do
      en, keys, orphaned, missing, dups = load_data
      puts orphaned.join("\n")
    end

    desc "list keys missing from tmp/en.yml"
    task :missing do
      en, keys, orphaned, missing, dups = load_data
      puts missing.join("\n")
    end

    desc "list duplicate values"
    task :dups do
      en, keys, orphaned, missing, dups = load_data
      puts dups.sort.join("\n")
    end

    #
    # for coding, it helps to have the english strings in separate files.
    # for translating, it helps to have a single file. This action will combine
    # the small files into one big one.
    #
    desc "combine locales/en/*.yml to tmp/en.yml"
    task :bundle do
      Dir.chdir('config/locales/') do
        en_yml = '../../tmp/en.yml'
        File.unlink(en_yml) if File.exists?(en_yml)
        File.open(en_yml, 'w') do |output|
          output.write("en:\n\n ### Do NOT edit this file directly, as all changes will be overwritten by the bundle script. Instead, make changes in the appropriate file in config/locales/en and recreate this file with the cg:i18n:bundle task.")

          Dir.glob('en/*.yml').sort.each do |file|
            ## print separator to see where another file begins
            output.write("\n\n" + '#' * 40 + "\n" + '### ' + file + "\n")
            output.write(
              # remove the toplevel "en" key
              YAML.load_file(file)['en'].
              to_yaml.
              # prefix all lines with two spaces (we're nested below "en:")
              lines.map {|line| "  #{line}"}[
                1..-1 # << skip the first line (it's "---" and freaks out the parser if it sees it multiple times in a file)
              ].join)
          end
        end
        puts "You can now find the bundled en.yml in: #{File.expand_path(en_yml, Dir.pwd)}"
      end
    end



# OR:
# find the orphaned keys.
# find each line that starts with an even number of spaces then orphaned key then a colon, and stick a !# at the beginning.
# this would break with multi-line translations
# or we could manually deal with multiline keys?
# if it has pipe, print out
# only find each key once.

    desc "comment out orphaned keys"
    task :disable do
      en, keys, orphaned, missing, dups = load_data
      Dir.chdir('config/locales/') do
        Dir.glob('en/*.yml').sort.each do |file|
        File.rename(file, "#{file}bak")
          File.open("#{file}bak", 'r') do |f_bak|
            File.open(file, 'w') do |f|
              while line = f_bak.gets
                orph = false
                orphaned.each do |orphan| #these are just top-level keys
                  if /^(\s\s)#{orphan}:/ =~ line  #orphans only have top-level keys so we are only looking for keys indented by 2
                    f.write('  ##!' + line)
                    orph = true
                    #break
                  end
                end
                f.write(line) if !orph
              end
            end
          end
          File.unlink("#{file}bak")
        end
      end
    end

    desc "pull translations from transifex"
    task :download do
      Conf.enabled_languages.each do |lang|
        next unless lang == 'en'
        `curl -L --user #{Conf.transifex_user}:#{Conf.transifex_password} -X GET https://www.transifex.net/api/2/project/crabgrass/resource/master/translation/#{lang}/?file > config/locales/#{lang}.yml`
      end
    end


  end
end

