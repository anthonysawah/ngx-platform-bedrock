variable "name_prefix" {
  type        = string
  description = "Prefix used for the bucket name and CloudFront comment."
}

variable "default_root_object" {
  type        = string
  description = "Default object served at /."
  default     = "index.html"
}

variable "price_class" {
  type        = string
  description = "CloudFront price class. PriceClass_100 = US/EU only, cheapest."
  default     = "PriceClass_100"
}
