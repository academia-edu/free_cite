# encoding: UTF-8

require 'free_cite/preprocessor'
require 'free_cite/postprocessor'
require 'free_cite/token_features'
require 'tempfile'

module FreeCite

  class CRFParser

    attr_reader :feature_order
    attr_reader :token_features

    include TokenFeatures
    include Preprocessor
    include Postprocessor

    DIR = File.dirname(__FILE__)
    TAGGED_REFERENCES = "#{DIR}/resources/trainingdata/tagged_references.txt"
    TRAINING_DATA = "#{DIR}/resources/trainingdata/training_data.txt"
    MODEL_FILE = "#{DIR}/resources/model"
    TEMPLATE_FILE = "#{DIR}/resources/parsCit.template"

    # Feature functions must be performed in alphabetical order, since
    # later functions may depend on earlier ones.
    # If you want to specify a specific output order, do so in a yaml file in
    # config. See ../../config/parscit_features.yml as an example
    # You may also use this config file to specify a subset of features to use
    # Just be careful not to exclude any functions that included functions
    # depend on
    def initialize(config_file="#{DIR}/../../config/parscit_features.yml")
      if config_file
        f = File.open(config_file, 'r')
        hsh = YAML::load( f )
        @feature_order = hsh["feature_order"].map(&:to_sym)
        @token_features = hsh["feature_order"].sort.map(&:to_sym)
      else
        @token_features = (TokenFeatures.instance_methods).sort.map(&:to_sym)
        @token_features.delete :clear
        @feature_order = @token_features
      end
    end

    def model
      @model ||= CRFPP::Tagger.new("-m #{MODEL_FILE} -v 1");
    end

    def parse_string(str, presumed_author=nil)
      raw_string = str.dup
      str = normalize_cite_text(str)
      features = str_2_features(str, false, presumed_author)
      tags, overall_prob, tag_probs = eval_crfpp(features)
      toks = str.scan(/\S*\s*/)
      ret = {}
      tags.each_with_index {|t, i|
        (ret[t] ||= '') << toks[i]
      }
      normalize_fields(ret)
      ret['raw_string'] = raw_string
      [ret, overall_prob, tag_probs]
    end

    def eval_crfpp(feat_seq)
      model.clear
      feat_seq.each {|vec|
        line = vec.join(" ").strip
        raise unless model.add(line)
      }
      raise unless model.parse
      tags = []
      probs = {}
      feat_seq.length.times {|i|
        tags << model.y2(i)
        probs[model.y2(i)] ||= 1
        probs[model.y2(i)] *= model.prob(i)
      }
      [tags, model.prob, probs]
    end

    def strip_punct(str)
      toknp = str.gsub(/[^\w]/, '')
      toknp = "EMPTY" if toknp.blank?
      toknp
    end

    def normalize_input_author(str)
      return nil if str.blank?
      str.split.map(&:downcase).map { |t| strip_punct(t) }
    end

    def prepare_token_data(cstr, training=false)
      cstr.strip!
      # split the string on whitespace and calculate features on each token
      tokens_and_tags = cstr.split(/\s+/)
      tag = nil
      self.clear

      # strip out any tags
      tokens = tokens_and_tags.reject {|t| t =~ /^<[\/]{0,1}([a-z]+)>$/}

      # strip tokens of punctuation
      tokensnp = tokens.map {|t| strip_punct(t) }

      # downcase stripped tokens
      tokenslcnp = tokensnp.map {|t| t == "EMPTY" ? "EMPTY" : t.downcase }
      return [tokens_and_tags, tokens, tokensnp, tokenslcnp]
    end

    # calculate features on the full citation string
    def str_2_features(cstr, training=false, presumed_author=nil)
      features = []
      tokens_and_tags, tokens, tokensnp, tokenslcnp = prepare_token_data(cstr, training)
      author_names = normalize_input_author(presumed_author)

      toki = 0
      tag = nil
      tokens_and_tags.each_with_index {|tok, i|
        # if this is training data, grab the mark-up tag and then skip it
        if training
          if tok =~ /^<([a-z]+)>$/
            tag = $1
            next
          elsif tok =~ /^<\/([a-z]+)>$/
            tok = nil
            raise TrainingError, "Mark-up tag mismatch #{tag} != #{$1}\n#{cstr}" if $1 != tag
            next
          end
        end
        feats = {}


        # If we are training, there should always be a tag defined
        if training && tok.nil?
          raise TrainingError, "Incorrect mark-up:\n #{cstr}"
        end
        @token_features.each {|f|
          feats[f] = self.send(f, tokens, tokensnp, tokenslcnp, toki, author_names)
        }
        toki += 1

        features << [tok]
        @feature_order.each {|f| features.last << feats[f]}
        features.last << tag if training

        if toki >= tokens.length
          break
        end
      }
      return features
    end

    def write_training_file(tagged_refs=TAGGED_REFERENCES,
      training_data=TRAINING_DATA)

      fin = File.open(tagged_refs, 'r')
      fout = File.open(training_data, 'w')
      x = 0
      while l = fin.gets
        #puts "processed a line #{x+=1}"
        data = str_2_features(l.strip, true)
        data.each {|line| fout.write("#{line.join(" ")}\n") }
        fout.write("\n")
      end

      fin.close
      fout.flush
      fout.close
    end

    def train(tagged_refs=TAGGED_REFERENCES, model=MODEL_FILE,
      template=TEMPLATE_FILE, training_data=nil)

      if training_data.nil?
        training_data = TRAINING_DATA
        write_training_file(tagged_refs, training_data)
      end
      `crf_learn #{template} #{training_data} #{model}`
    end

  end

  class TrainingError < Exception; end

end
