﻿using Microsoft.AspNetCore.Mvc.ModelBinding;
using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Linq;
using System.Threading.Tasks;

namespace EDC_API.Models
{
    public class ProductionDataRequest : ProductionData
    {
        [JsonIgnore]
        public override int Id { get; set; }
    }
}
